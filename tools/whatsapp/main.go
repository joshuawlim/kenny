package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"github.com/mdp/qrterminal"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
)

// WhatsApp message logger - minimal version for Kenny integration
type WhatsAppLogger struct {
	client *whatsmeow.Client
	store  *MessageStore
	log    waLog.Logger
}

// Message store handles SQLite database operations
type MessageStore struct {
	db *sql.DB
}

// Initialize message store with schema from whatsapp-mcp
func NewMessageStore(dbPath string) (*MessageStore, error) {
	// Create directory if it doesn't exist
	if err := os.MkdirAll(filepath.Dir(dbPath), 0755); err != nil {
		return nil, fmt.Errorf("failed to create directory: %v", err)
	}

	// Open SQLite database
	db, err := sql.Open("sqlite3", fmt.Sprintf("file:%s?_foreign_keys=on", dbPath))
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %v", err)
	}

	// Create tables with schema from whatsapp-mcp
	schema := `
		CREATE TABLE IF NOT EXISTS chats (
			jid TEXT PRIMARY KEY,
			name TEXT,
			last_message_time TIMESTAMP
		);
		
		CREATE TABLE IF NOT EXISTS messages (
			id TEXT,
			chat_jid TEXT,
			sender TEXT,
			content TEXT,
			timestamp TIMESTAMP,
			is_from_me BOOLEAN,
			media_type TEXT,
			filename TEXT,
			url TEXT,
			media_key BLOB,
			file_sha256 BLOB,
			file_enc_sha256 BLOB,
			file_length INTEGER,
			PRIMARY KEY (id, chat_jid),
			FOREIGN KEY (chat_jid) REFERENCES chats(jid)
		);
		
		CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp);
		CREATE INDEX IF NOT EXISTS idx_messages_chat_jid ON messages(chat_jid);
	`

	if _, err = db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("failed to create schema: %v", err)
	}

	return &MessageStore{db: db}, nil
}

// Close the database connection
func (s *MessageStore) Close() error {
	return s.db.Close()
}

// Store a chat in the database
func (s *MessageStore) StoreChat(jid, name string, lastMessageTime time.Time) error {
	query := `INSERT OR REPLACE INTO chats (jid, name, last_message_time) VALUES (?, ?, ?)`
	_, err := s.db.Exec(query, jid, name, lastMessageTime)
	return err
}

// Store a message in the database
func (s *MessageStore) StoreMessage(id, chatJID, sender, content string, timestamp time.Time, isFromMe bool, mediaType, filename, url string) error {
	query := `INSERT OR REPLACE INTO messages 
		(id, chat_jid, sender, content, timestamp, is_from_me, media_type, filename, url)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
	
	_, err := s.db.Exec(query, id, chatJID, sender, content, timestamp, isFromMe, mediaType, filename, url)
	return err
}

// Create new WhatsApp logger
func NewWhatsAppLogger(sessionDBPath, messagesDBPath string) (*WhatsAppLogger, error) {
	// Initialize message store
	store, err := NewMessageStore(messagesDBPath)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize message store: %v", err)
	}

	// Initialize whatsmeow session store with foreign keys enabled
	dbLog := waLog.Stdout("Database", "INFO", true)
	
	// Create session database with foreign keys enabled
	sessionDBPathWithPragma := fmt.Sprintf("file:%s?_foreign_keys=on", sessionDBPath)
	container, err := sqlstore.New(context.Background(), "sqlite3", sessionDBPathWithPragma, dbLog)
	if err != nil {
		store.Close()
		return nil, fmt.Errorf("failed to initialize session store: %v", err)
	}

	// Get device (will be nil if not registered)
	deviceStore, err := container.GetFirstDevice(context.Background())
	if err != nil {
		store.Close()
		return nil, fmt.Errorf("failed to get device: %v", err)
	}

	// Initialize client
	clientLog := waLog.Stdout("Client", "INFO", true)
	client := whatsmeow.NewClient(deviceStore, clientLog)

	logger := &WhatsAppLogger{
		client: client,
		store:  store,
		log:    clientLog,
	}

	// Register event handlers
	client.AddEventHandler(logger.handleEvent)

	return logger, nil
}

// Handle WhatsApp events
func (w *WhatsAppLogger) handleEvent(evt interface{}) {
	switch v := evt.(type) {
	case *events.Message:
		w.handleMessage(v)
	case *events.HistorySync:
		w.handleHistorySync(v)
	case *events.ChatPresence:
		w.handleChatUpdate(v.MessageSource.Chat.String(), "", time.Now())
	case *events.Connected:
		w.log.Infof("Connected to WhatsApp - requesting message history...")
		w.requestHistorySync()
	case *events.LoggedOut:
		w.log.Infof("Logged out: %v", v)
	}
}

// Handle incoming messages
func (w *WhatsAppLogger) handleMessage(msg *events.Message) {
	// Extract basic message info
	chatJID := msg.Info.Chat.String()
	sender := msg.Info.Sender.String()
	messageID := msg.Info.ID
	timestamp := msg.Info.Timestamp
	isFromMe := msg.Info.IsFromMe

	// Extract content based on message type
	var content, mediaType, filename string
	
	if msg.Message.Conversation != nil {
		content = *msg.Message.Conversation
	} else if msg.Message.ExtendedTextMessage != nil {
		content = *msg.Message.ExtendedTextMessage.Text
	} else if msg.Message.ImageMessage != nil {
		content = "[Image]"
		mediaType = "image"
		if msg.Message.ImageMessage.Caption != nil {
			content += " " + *msg.Message.ImageMessage.Caption
		}
	} else if msg.Message.VideoMessage != nil {
		content = "[Video]"
		mediaType = "video"
		if msg.Message.VideoMessage.Caption != nil {
			content += " " + *msg.Message.VideoMessage.Caption
		}
	} else if msg.Message.AudioMessage != nil {
		content = "[Audio]"
		mediaType = "audio"
	} else if msg.Message.DocumentMessage != nil {
		content = "[Document]"
		mediaType = "document"
		if msg.Message.DocumentMessage.FileName != nil {
			filename = *msg.Message.DocumentMessage.FileName
			content += " " + filename
		}
	} else {
		content = "[Unknown message type]"
	}

	// Store message
	if err := w.store.StoreMessage(messageID, chatJID, sender, content, timestamp, isFromMe, mediaType, filename, ""); err != nil {
		w.log.Errorf("Failed to store message: %v", err)
	} else {
		w.log.Infof("Stored message: %s from %s in %s", content, sender, chatJID)
	}

	// Update chat info
	chatName := chatJID // Default to JID
	if err := w.store.StoreChat(chatJID, chatName, timestamp); err != nil {
		w.log.Errorf("Failed to update chat: %v", err)
	}
}

// Handle message updates would go here if needed
// (MessageUpdate events are not available in this version)

// Handle chat updates
func (w *WhatsAppLogger) handleChatUpdate(chatJID, chatName string, lastMessage time.Time) {
	if chatName == "" {
		chatName = chatJID
	}
	if err := w.store.StoreChat(chatJID, chatName, lastMessage); err != nil {
		w.log.Errorf("Failed to update chat: %v", err)
	}
}

// Connect to WhatsApp
func (w *WhatsAppLogger) Connect() error {
	if w.client.Store.ID == nil {
		// Not registered, need to scan QR code
		qrChan, _ := w.client.GetQRChannel(context.Background())
		err := w.client.Connect()
		if err != nil {
			return fmt.Errorf("failed to connect: %v", err)
		}

		for evt := range qrChan {
			if evt.Event == "code" {
				w.log.Infof("QR code received, please scan with your phone:")
				qrterminal.GenerateHalfBlock(evt.Code, qrterminal.L, os.Stdout)
			} else {
				w.log.Infof("Login event: %s", evt.Event)
				if evt.Event == "success" {
					break
				}
			}
		}
	} else {
		// Already registered, just connect
		err := w.client.Connect()
		if err != nil {
			return fmt.Errorf("failed to connect: %v", err)
		}
		w.log.Infof("Connected with existing session")
	}

	return nil
}

// Disconnect from WhatsApp
func (w *WhatsAppLogger) Disconnect() {
	if w.client != nil {
		w.client.Disconnect()
	}
	if w.store != nil {
		w.store.Close()
	}
}

// Query messages for Kenny integration
func (w *WhatsAppLogger) QueryMessages(chatJID string, limit int) ([]map[string]interface{}, error) {
	query := `SELECT id, chat_jid, sender, content, timestamp, is_from_me, media_type, filename 
		FROM messages WHERE chat_jid = ? ORDER BY timestamp DESC LIMIT ?`
	
	rows, err := w.store.db.Query(query, chatJID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var messages []map[string]interface{}
	for rows.Next() {
		var id, chatJID, sender, content, mediaType, filename string
		var timestamp time.Time
		var isFromMe bool
		
		err := rows.Scan(&id, &chatJID, &sender, &content, &timestamp, &isFromMe, &mediaType, &filename)
		if err != nil {
			continue
		}
		
		messages = append(messages, map[string]interface{}{
			"id":         id,
			"chat_jid":   chatJID,
			"sender":     sender,
			"content":    content,
			"timestamp":  timestamp,
			"is_from_me": isFromMe,
			"media_type": mediaType,
			"filename":   filename,
		})
	}
	
	return messages, nil
}

// Request full history sync from WhatsApp
func (w *WhatsAppLogger) requestHistorySync() {
	if !w.client.IsConnected() {
		w.log.Warnf("Cannot request history sync - client not connected")
		return
	}

	if w.client.Store.ID == nil {
		w.log.Warnf("Cannot request history sync - client not logged in")
		return
	}

	// Request multiple batches to get comprehensive history
	batchSizes := []int{10000, 5000, 2000}  // Try different batch sizes
	
	for i, batchSize := range batchSizes {
		w.log.Infof("Requesting history sync batch %d/%d (%d messages)...", i+1, len(batchSizes), batchSize)
		
		// Build and send a history sync request
		historyMsg := w.client.BuildHistorySyncRequest(nil, batchSize)
		if historyMsg == nil {
			w.log.Errorf("Failed to build history sync request for batch %d", i+1)
			continue
		}

		_, err := w.client.SendMessage(context.Background(), types.JID{
			Server: "s.whatsapp.net",
			User:   "status",
		}, historyMsg)

		if err != nil {
			w.log.Errorf("Failed to request history sync batch %d: %v", i+1, err)
		} else {
			w.log.Infof("History sync batch %d requested successfully", i+1)
		}
		
		// Wait between requests to avoid overwhelming the server
		if i < len(batchSizes)-1 {
			time.Sleep(3 * time.Second)
		}
	}
	
	w.log.Infof("All history sync requests sent. Messages will appear as they are processed...")
}

// Handle history sync events
func (w *WhatsAppLogger) handleHistorySync(historySync *events.HistorySync) {
	w.log.Infof("Received history sync event with %d conversations", len(historySync.Data.Conversations))

	syncedCount := 0
	for _, conversation := range historySync.Data.Conversations {
		// Parse JID from the conversation
		if conversation.ID == nil {
			continue
		}

		chatJID := *conversation.ID

		// Try to parse the JID
		jid, err := types.ParseJID(chatJID)
		if err != nil {
			w.log.Warnf("Failed to parse JID %s: %v", chatJID, err)
			continue
		}

		// Get chat name (simplified version)
		name := chatJID
		if jid.Server == "g.us" {
			name = fmt.Sprintf("Group %s", jid.User[:8]) // Shortened group name
		} else {
			name = jid.User // Individual chat
		}

		// Process messages
		messages := conversation.Messages
		if len(messages) > 0 {
			// Update chat with latest message timestamp
			latestMsg := messages[0]
			if latestMsg == nil || latestMsg.Message == nil {
				continue
			}

			// Get timestamp from message info
			timestamp := time.Time{}
			if ts := latestMsg.Message.GetMessageTimestamp(); ts != 0 {
				timestamp = time.Unix(int64(ts), 0)
			} else {
				continue
			}

			w.store.StoreChat(chatJID, name, timestamp)

			// Store messages
			for _, msg := range messages {
				if msg == nil || msg.Message == nil {
					continue
				}

				// Extract text content
				var content string
				if msg.Message.Message != nil {
					if conv := msg.Message.Message.GetConversation(); conv != "" {
						content = conv
					} else if ext := msg.Message.Message.GetExtendedTextMessage(); ext != nil {
						content = ext.GetText()
					}
				}

				// Skip empty messages for now (could add media handling later)
				if content == "" {
					continue
				}

				// Determine sender
				var sender string
				isFromMe := false
				if msg.Message.Key != nil {
					if msg.Message.Key.FromMe != nil {
						isFromMe = *msg.Message.Key.FromMe
					}
					if !isFromMe && msg.Message.Key.Participant != nil && *msg.Message.Key.Participant != "" {
						sender = *msg.Message.Key.Participant
					} else if isFromMe {
						sender = w.client.Store.ID.User
					} else {
						sender = jid.User
					}
				} else {
					sender = jid.User
				}

				// Store message
				msgID := ""
				if msg.Message.Key != nil && msg.Message.Key.ID != nil {
					msgID = *msg.Message.Key.ID
				}

				// Get message timestamp
				timestamp := time.Time{}
				if ts := msg.Message.GetMessageTimestamp(); ts != 0 {
					timestamp = time.Unix(int64(ts), 0)
				} else {
					continue
				}

				err = w.store.StoreMessage(
					msgID,
					chatJID,
					sender,
					content,
					timestamp,
					isFromMe,
					"", // No media type for now
					"", // No filename
					"", // No URL
				)
				if err != nil {
					w.log.Warnf("Failed to store history message: %v", err)
				} else {
					syncedCount++
				}
			}
		}
	}

	w.log.Infof("🔄 History sync batch complete. Stored %d messages from %d conversations.", syncedCount, len(historySync.Data.Conversations))
	
	// Get total message count from database
	var totalCount int
	w.store.db.QueryRow("SELECT COUNT(*) FROM messages").Scan(&totalCount)
	w.log.Infof("📱 Total messages in database: %d", totalCount)
}

func main() {
	if len(os.Args) < 2 {
		log.Fatal("Usage: go run main.go [start|status|query]")
	}

	command := strings.ToLower(os.Args[1])
	sessionDBPath := "whatsapp_session.db"
	messagesDBPath := "whatsapp_messages.db"

	switch command {
	case "start":
		// Start the WhatsApp logger
		logger, err := NewWhatsAppLogger(sessionDBPath, messagesDBPath)
		if err != nil {
			log.Fatalf("Failed to create logger: %v", err)
		}
		defer logger.Disconnect()

		if err := logger.Connect(); err != nil {
			log.Fatalf("Failed to connect: %v", err)
		}

		log.Println("WhatsApp logger started. Press Ctrl+C to stop...")

		// Wait for interrupt signal
		c := make(chan os.Signal, 1)
		signal.Notify(c, os.Interrupt, syscall.SIGTERM)
		<-c

		log.Println("Shutting down...")

	case "status":
		// Check status
		store, err := NewMessageStore(messagesDBPath)
		if err != nil {
			log.Fatalf("Failed to open database: %v", err)
		}
		defer store.Close()

		// Count messages and chats
		var messageCount, chatCount int
		store.db.QueryRow("SELECT COUNT(*) FROM messages").Scan(&messageCount)
		store.db.QueryRow("SELECT COUNT(*) FROM chats").Scan(&chatCount)

		fmt.Printf("WhatsApp Logger Status:\n")
		fmt.Printf("Database: %s\n", messagesDBPath)
		fmt.Printf("Messages: %d\n", messageCount)
		fmt.Printf("Chats: %d\n", chatCount)

	case "query":
		// Query recent messages
		if len(os.Args) < 3 {
			log.Fatal("Usage: go run main.go query <chat_jid>")
		}
		
		chatJID := os.Args[2]
		logger, err := NewWhatsAppLogger(sessionDBPath, messagesDBPath)
		if err != nil {
			log.Fatalf("Failed to create logger: %v", err)
		}
		defer logger.Disconnect()

		messages, err := logger.QueryMessages(chatJID, 10)
		if err != nil {
			log.Fatalf("Failed to query messages: %v", err)
		}

		fmt.Printf("Recent messages from %s:\n", chatJID)
		for _, msg := range messages {
			fmt.Printf("[%v] %s: %s\n", msg["timestamp"], msg["sender"], msg["content"])
		}

	default:
		log.Fatal("Unknown command. Use: start, status, or query")
	}
}