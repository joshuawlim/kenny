-- Controlled sample dataset for Week 3 hybrid search testing
-- This creates realistic test data for the audit validation

-- Clear any existing test data first
DELETE FROM documents WHERE id LIKE 'test-%';
DELETE FROM documents_fts WHERE documents_fts MATCH 'test-*';

-- Sample Email Documents
INSERT INTO documents (id, type, title, content, app_source, source_id, source_path, hash, created_at, updated_at, last_seen_at, deleted) VALUES 
('test-email-apollo', 'email', 'Project Apollo Status Update', 'Subject: Project Apollo Status Update - March Milestone Review

Hi Team,

I wanted to provide you with a comprehensive update on Project Apollo as we approach our March milestone.

Current Status:
- Backend API development: 85% complete
- Frontend components: 70% complete  
- Database migration scripts: 100% complete
- Integration testing: 60% complete

Key Achievements This Sprint:
- Successfully implemented user authentication system
- Completed core data models and relationships
- Set up CI/CD pipeline with automated testing

Upcoming Deliverables:
- User interface polishing (Due: March 15)
- Performance optimization (Due: March 20)
- Security audit completion (Due: March 25)

Budget Status:
- Current spend: $127,000 of $180,000 allocated
- On track to deliver within budget constraints

Next Steps:
- Focus on UI/UX improvements
- Complete integration testing by end of week
- Schedule final stakeholder review for March 28

Let me know if you have any questions or concerns.

Best regards,
Sarah Chen
Project Manager', 'Mail', 'apollo-email-001', 'message://apollo-status-march-2024', 'hash-apollo-email', 1710444000, 1710444000, 1710444000, 0),

('test-email-budget', 'email', 'Budget Review Q2 - Action Required', 'Subject: Budget Review Q2 - Action Required

Team,

As we prepare for our Q2 budget review meeting scheduled for next week, I need everyone to submit their departmental budget requests by Friday.

Q2 Budget Review Process:
1. Submit initial budget requests (Due: This Friday)
2. Department head review and consolidation (Next Monday)
3. Executive review meeting (Next Wednesday)
4. Final budget approval (Following Friday)

Key Areas of Focus:
- Infrastructure and tooling investments
- Team expansion requirements
- Training and development allocations
- Marketing and sales support

Budget Guidelines:
- Maximum 15% increase from Q1 approved budget
- All requests must include detailed justification
- ROI projections required for investments >$10k
- Consider cost-saving measures where possible

Please use the standard budget template (attached) and submit via the finance portal.

Questions? Reach out to me directly.

Thanks,
Michael Rodriguez  
Finance Director', 'Mail', 'budget-q2-001', 'message://budget-review-q2-2024', 'hash-budget-email', 1710358000, 1710358000, 1710358000, 0);

-- Sample Notes Documents  
INSERT INTO documents (id, type, title, content, app_source, source_id, source_path, hash, created_at, updated_at, last_seen_at, deleted) VALUES
('test-note-1on1', 'note', '1:1 with Jon Larsen - Action Items', 'Meeting Date: March 10, 2024
Attendees: Jon Larsen (Engineering Manager), Alex Kim (Senior Developer)

Discussion Topics:

1. Current Project Status
   - Jon provided update on microservices migration
   - 3 out of 5 services successfully migrated
   - Performance improvements of 40% observed
   - Remaining services scheduled for next sprint

2. Team Capacity and Workload
   - Team is currently at 95% capacity
   - Need to consider bringing in contractor for Q2 surge
   - Jon to evaluate junior developer candidates

3. Technical Debt Priorities
   - Legacy authentication system needs refactoring
   - Database indexing optimization required
   - API documentation updates needed

Action Items:
• Jon: Schedule architecture review meeting by March 15
• Alex: Complete performance benchmarking by March 18  
• Jon: Interview contractor candidates by March 22
• Alex: Document API endpoints and submit PR by March 20
• Both: Review and prioritize tech debt backlog by March 25

Next Meeting: March 17, 2024 at 2:00 PM

Notes:
- Jon mentioned the new monitoring dashboard is showing great insights
- Team morale is high despite increased workload
- Consider implementing pair programming for complex features', 'Notes', 'note-1on1-larsen', 'x-coredata://note-1on1-jon-larsen-march', 'hash-note-1on1', 1710108000, 1710108000, 1710108000, 0),

('test-note-design', 'note', 'Design Decisions: Sync vs Async Processing', 'Design Decision Log: Synchronous vs Asynchronous Processing
Date: March 12, 2024
Decision Owner: Technical Architecture Team

Problem Statement:
Our current data processing pipeline handles user uploads synchronously, causing timeout issues for large files (>50MB) and poor user experience during peak hours.

Options Evaluated:

1. Synchronous Processing (Current State)
   Pros:
   - Simple error handling
   - Immediate feedback to user
   - Easier to debug and trace
   
   Cons:
   - Timeout issues with large files
   - Poor scalability under load
   - Blocks other operations during processing

2. Asynchronous Processing with Queue
   Pros:
   - Better scalability and throughput
   - Non-blocking user experience  
   - Can handle large files without timeouts
   - Retry mechanism for failed jobs
   
   Cons:
   - More complex error handling
   - Need job status tracking system
   - Requires additional infrastructure (queue system)

3. Hybrid Approach  
   Pros:
   - Small files processed synchronously
   - Large files routed to async queue
   - Best of both approaches
   
   Cons:
   - Added complexity in routing logic
   - Need to maintain both code paths

Decision: Implement Asynchronous Processing with Queue

Rationale:
- User experience improvement is critical for retention
- Scalability requirements for Q2 growth projections  
- Infrastructure cost increase is acceptable (<$2000/month)
- Team has experience with Redis and job queuing

Implementation Plan:
1. Set up Redis cluster for job queue
2. Implement job worker processes
3. Add job status tracking to database
4. Create user notification system for job completion
5. Migrate existing processing to async queue

Success Metrics:
- 0 timeout errors for file uploads
- <2 second response time for upload initiation
- 99.9% job completion rate
- User satisfaction score improvement

Next Steps:
- Technical spike for Redis setup (Sprint 23)
- UI mockups for job status tracking (Sprint 23)  
- Implementation begins Sprint 24', 'Notes', 'note-design-sync-async', 'x-coredata://note-design-decisions-sync-async', 'hash-note-design', 1710194000, 1710194000, 1710194000, 0);

-- Sample Calendar Event
INSERT INTO documents (id, type, title, content, app_source, source_id, source_path, hash, created_at, updated_at, last_seen_at, deleted) VALUES
('test-event-offsite', 'event', 'Team Offsite Planning - Q2 Strategy', 'Event: Team Offsite Planning - Q2 Strategy Session
Date: March 22, 2024
Time: 9:00 AM - 5:00 PM PST
Location: Redwood Conference Center, 1455 El Camino Real, Palo Alto, CA

Attendees:
- Sarah Chen (Project Manager) - Organizer
- Jon Larsen (Engineering Manager)  
- Michael Rodriguez (Finance Director)
- Lisa Wang (Product Manager)
- David Park (Design Lead)
- Alex Kim (Senior Developer)
- Maria Garcia (Marketing Manager)

Agenda:

9:00 AM - 9:30 AM: Welcome & Coffee
- Team introductions for new members
- Overview of offsite objectives

9:30 AM - 11:00 AM: Q1 Retrospective  
- What went well analysis
- Areas for improvement identification
- Lessons learned documentation

11:00 AM - 11:15 AM: Break

11:15 AM - 12:30 PM: Q2 Strategy Planning
- Market analysis and competitive landscape
- Product roadmap prioritization
- Resource allocation discussions

12:30 PM - 1:30 PM: Lunch (catered)

1:30 PM - 3:00 PM: Team Building Activity
- Problem-solving simulation exercise
- Cross-functional collaboration workshop

3:00 PM - 3:15 PM: Break

3:15 PM - 4:30 PM: Q2 Goal Setting
- OKR definition and alignment
- Success metrics identification
- Timeline and milestone planning

4:30 PM - 5:00 PM: Next Steps & Action Items
- Responsibility assignments
- Follow-up meeting scheduling
- Feedback collection

Logistics:
- Transportation: Shuttle service from office at 8:30 AM
- Accommodation: N/A (day event)
- Catering: Breakfast pastries, lunch, afternoon snacks
- Materials: Whiteboards, projectors, notebooks provided
- Parking: Free on-site parking available

Pre-Work Required:
- Review Q1 performance metrics (due March 20)
- Prepare department-specific challenges list (due March 21)
- Complete team dynamics survey (due March 21)

Post-Event Deliverables:
- Meeting notes and action items (March 25)
- Updated roadmap documentation (March 28)
- Team feedback compilation (March 29)', 'Calendar', 'event-offsite-q2-2024', 'x-apple-eventkit://event-team-offsite-march', 'hash-event-offsite', 1711094400, 1711094400, 1711094400, 0);

-- Sample File Document
INSERT INTO documents (id, type, title, content, app_source, source_id, source_path, hash, created_at, updated_at, last_seen_at, deleted) VALUES
('test-file-roadmap', 'file', 'Roadmap.md - Product Development Plan', '# Product Development Roadmap 2024

## Executive Summary

This document outlines our comprehensive product development strategy for 2024, focusing on user experience improvements, scalability enhancements, and market expansion.

## Q1 2024 Milestones (January - March)

### Infrastructure & Performance
- [x] Database migration to PostgreSQL cluster
- [x] API response time optimization (target: <200ms)
- [x] CDN implementation for static assets
- [ ] Load balancing configuration (In Progress)

### User Experience
- [x] Mobile app responsive design updates  
- [x] Dark mode implementation
- [ ] Advanced search functionality (80% complete)
- [ ] User onboarding flow redesign

### Security & Compliance
- [x] SOC 2 Type I audit completion
- [x] GDPR compliance review and updates
- [ ] Multi-factor authentication rollout
- [ ] Data encryption at rest implementation

## Q2 2024 Roadmap (April - June)

### New Features
- Advanced analytics dashboard for enterprise users
- Real-time collaboration tools
- API rate limiting and usage analytics
- Automated backup and disaster recovery

### Platform Expansion  
- Integration with Slack and Microsoft Teams
- Webhook support for third-party applications
- iOS and Android mobile app store releases
- Browser extension development

### Scalability Improvements
- Microservices architecture migration (Phase 2)
- Container orchestration with Kubernetes
- Automated testing pipeline enhancement
- Performance monitoring and alerting system

## Q3 2024 Objectives (July - September)

### Enterprise Features
- Single Sign-On (SSO) integration
- Advanced user permission management
- Audit logging and compliance reporting
- Custom branding options for enterprise clients

### AI/ML Capabilities
- Intelligent content recommendations
- Automated data categorization
- Predictive analytics for user behavior
- Natural language search improvements

### International Expansion
- Multi-language support (Spanish, French, German)
- Currency support for international markets
- Regional data center deployment
- Local compliance requirements research

## Q4 2024 Vision (October - December)

### Innovation Projects
- Machine learning model integration
- Advanced workflow automation
- Voice interface development
- Augmented reality features exploration

### Market Growth
- Partnership program launch
- Reseller channel development
- Industry-specific solution packages
- Academic and non-profit pricing tiers

## Resource Requirements

### Engineering Team
- 2 additional senior developers (Q1)
- 1 DevOps engineer (Q2) 
- 1 mobile developer (Q2)
- 1 QA automation specialist (Q3)

### Infrastructure Investment
- Cloud services scaling: $50k/quarter
- Security tools and compliance: $25k/quarter  
- Monitoring and analytics tools: $15k/quarter
- Development tools and licenses: $10k/quarter

## Success Metrics

### Performance KPIs
- Application uptime: >99.9%
- API response time: <200ms P95
- Page load speed: <3 seconds
- Mobile app crash rate: <0.1%

### Business KPIs  
- Monthly Active Users growth: 25% QoQ
- Customer retention rate: >95%
- Net Promoter Score: >50
- Revenue growth: 40% YoY

### Development KPIs
- Feature delivery velocity: +30% vs 2023
- Bug resolution time: <2 days average
- Code coverage: >80%
- Security vulnerabilities: 0 high/critical

## Risk Assessment

### Technical Risks
- Database migration complexity (Medium risk)
- Third-party API dependencies (Low risk)
- Scalability challenges during peak usage (Medium risk)

### Market Risks  
- Competitive pressure from established players (High risk)
- Economic downturn affecting enterprise budgets (Medium risk)
- Regulatory changes in data privacy (Low risk)

### Mitigation Strategies
- Comprehensive testing for all migrations
- Fallback plans for critical third-party services
- Gradual rollout of major features
- Diversified revenue streams development

## Conclusion

The 2024 roadmap positions us for significant growth while maintaining our commitment to security, performance, and user experience. Regular quarterly reviews will ensure we adapt to market changes and customer feedback.

For questions or feedback, contact the product team at product@company.com.

---
*Last updated: March 1, 2024*
*Next review: June 1, 2024*', 'Files', 'file-roadmap-2024', '/Users/team/Documents/Product/Roadmap.md', 'hash-file-roadmap', 1709251200, 1710460800, 1710460800, 0);

-- Verify the test data was inserted
SELECT 'Test data inserted successfully:' as message;
SELECT id, type, title, app_source FROM documents WHERE id LIKE 'test-%' ORDER BY type, id;