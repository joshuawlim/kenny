# Kenny Configuration Guide

This document describes how to configure Kenny for different environments.

## Environment Variables

### Database Configuration

- `KENNY_DB_PATH`: Absolute path to the Kenny database file
  - Example: `/path/to/your/kenny.db`
  - Default: Auto-detected based on project structure

- `KENNY_PROJECT_ROOT`: Root directory of the Kenny project
  - Example: `/Users/yourname/Documents/Kenny`
  - Default: Auto-detected by traversing up from current directory

### Environment Detection

- `KENNY_ENV`: Set the Kenny environment
  - Values: `development`, `testing`, `staging`, `production`
  - Default: `development` in DEBUG builds, `production` in release builds

### LLM Configuration

- `OLLAMA_ENDPOINT`: Ollama server endpoint (staging/production)
  - Example: `http://localhost:11434`
  - Default: `http://localhost:11434`

- `LLM_MODEL`: LLM model to use (production only)
  - Example: `llama3.2:3b`
  - Default: `mistral-small3.1:latest`

### Monitoring

- `METRICS_ENDPOINT`: Endpoint for metrics collection (staging/production)
  - Example: `http://metrics.yourcompany.com`
  - Default: Disabled

## Configuration by Environment

### Development
- Database: Auto-detected project path
- Caching: Enabled (100MB, 5 minutes TTL)
- Logging: Debug level with tracing
- LLM: Local Ollama with fallback

### Testing
- Database: In-memory (`:memory:`)
- Caching: Disabled
- Logging: Warning level only
- LLM: Mock provider

### Staging
- Database: Auto-detected project path
- Caching: Enabled (256MB, 10 minutes TTL)
- Logging: Info level with structured logging
- LLM: Ollama with environment endpoint override

### Production
- Database: Auto-detected project path
- Caching: Enabled (512MB, 15 minutes TTL)
- Logging: Warning level only
- LLM: Environment-configured model and endpoint

## Usage Examples

### Set custom database path
```bash
export KENNY_DB_PATH="/custom/path/to/kenny.db"
./orchestrator_cli search "your query"
```

### Use staging environment
```bash
export KENNY_ENV=staging
export OLLAMA_ENDPOINT="http://staging-llm.company.com:11434"
./orchestrator_cli search "your query"
```

### Set project root for multi-user setup
```bash
export KENNY_PROJECT_ROOT="/shared/kenny"
export KENNY_DB_PATH="/shared/kenny/kenny.db"
./orchestrator_cli search "your query"
```

## Path Resolution Logic

1. Check `KENNY_DB_PATH` environment variable (highest priority)
2. Use configuration path if specified
3. Auto-detect using `KENNY_PROJECT_ROOT` if set
4. Traverse up from current directory to find project markers:
   - `Package.swift`
   - `Sources/` directory
   - `OrchestratorCLI.swift`
5. Fallback to current directory + `kenny.db`

## Debugging Configuration

Use the built-in debug command to see current configuration:

```bash
./orchestrator_cli debug-config
```

This will show:
- Current environment
- Resolved database path
- Configuration values
- Environment variables affecting Kenny