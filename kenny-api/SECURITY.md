# Kenny API Security Documentation

## Security Measures Implemented

### Authentication & Authorization
- **API Key Required**: All endpoints require `Authorization: Bearer {KENNY_API_KEY}` header
- **Environment Variable**: API key must be set via `KENNY_API_KEY` environment variable
- **No Default Keys**: Application fails to start without proper API key configuration

### CORS Protection
- **Restricted Origins**: Configurable via `KENNY_ALLOWED_ORIGINS` environment variable
- **No Wildcards**: Default only allows `http://localhost:3000` for development
- **Specific Methods**: Only allows necessary HTTP methods (GET, POST, PUT, DELETE, OPTIONS)

### Input Validation
- **Pydantic Models**: All request bodies validated with strict type checking
- **Query Parameters**: Length limits and constraints on all search parameters
- **Sanitization**: Basic XSS and injection prevention in query strings
- **Contact ID Validation**: Format validation for contact identifiers

### Command Injection Prevention
- **Argument Validation**: Orchestrator commands validate all arguments for dangerous characters
- **No Shell Execution**: Uses `asyncio.create_subprocess_exec` with argument lists, not shell commands
- **Timeout Protection**: 30-second timeout on all subprocess executions
- **Whitelist Validation**: Only allows specific orchestrator tool names

### Database Security
- **Parameterized Queries**: All database queries use proper parameter binding
- **Connection Management**: Database connections properly managed and closed
- **SQLite Pragmas**: Foreign key constraints and WAL mode enabled for data integrity

### Error Handling
- **No Information Leakage**: Generic error messages prevent internal information disclosure
- **Proper HTTP Status Codes**: Appropriate status codes for different error types
- **Logging**: Security events logged for monitoring

## Deployment Security Checklist

### Before Production Deployment:

1. **Environment Variables**:
   - [ ] Set strong `KENNY_API_KEY` (minimum 32 characters, random)
   - [ ] Configure `KENNY_ALLOWED_ORIGINS` with actual frontend domains
   - [ ] Never commit `.env` files to version control

2. **Network Security**:
   - [ ] Use HTTPS only in production (configure via reverse proxy)
   - [ ] Configure firewall to only allow necessary ports
   - [ ] Use Cloudflare tunnel or similar secure tunnel service

3. **Database Security**:
   - [ ] Ensure database files have appropriate file permissions (600)
   - [ ] Regular database backups
   - [ ] Monitor database file sizes for unusual growth

4. **Monitoring**:
   - [ ] Set up logging aggregation
   - [ ] Monitor failed authentication attempts
   - [ ] Track API usage patterns

### Security Headers (Recommended via Reverse Proxy):
```
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
X-XSS-Protection: 1; mode=block
Strict-Transport-Security: max-age=31536000; includeSubDomains
```

## Incident Response

If you suspect a security breach:

1. **Immediate Actions**:
   - Rotate API keys immediately
   - Check logs for suspicious activity patterns
   - Review recent database changes

2. **Investigation**:
   - Examine access logs for unauthorized requests
   - Check database integrity
   - Review system logs for unusual subprocess executions

3. **Recovery**:
   - Update security configurations
   - Apply any necessary patches
   - Monitor for continued suspicious activity

## Known Limitations

- **Personal Data**: This system processes personal communications data
- **Local Storage**: All data stored locally - ensure proper backup and encryption
- **Single API Key**: Currently uses single API key authentication (could be enhanced with JWT/OAuth)
- **Rate Limiting**: No built-in rate limiting (recommend implementing via reverse proxy)

## Contact

For security concerns or to report vulnerabilities, please review the codebase and implement additional security measures as needed for your specific deployment environment.