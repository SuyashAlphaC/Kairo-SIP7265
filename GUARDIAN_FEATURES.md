# Advanced Guardian System Implementation

## Overview
This document describes the advanced guardian functionalities that have been implemented in the Circuit Breaker system, extending beyond basic guardian management to provide comprehensive security and governance capabilities.

## Implemented Features

### 1. Emergency Response System
**Guardian Emergency Pause**
- **Function**: `guardian_emergency_pause()`
- **Description**: Allows any guardian to immediately pause the entire protocol
- **Access Control**: Only registered guardians can trigger emergency pause
- **Use Case**: Critical security incidents, detected exploits, or urgent maintenance
- **Event**: `GuardianEmergencyPause` with guardian address and timestamp

### 2. Multi-Signature Rate Limit Override
**Proposal System**
- **Function**: `guardian_propose_rate_limit_override(proposal_id)`  
- **Description**: Guardians can propose to override active rate limits
- **Process**: Proposer automatically votes in favor (vote count = 1)
- **Event**: `GuardianOverrideProposed`

**Voting System**
- **Function**: `guardian_vote_rate_limit_override(proposal_id, approve)`
- **Description**: Other guardians vote for/against proposals
- **Restrictions**: Each guardian can only vote once per proposal
- **Event**: `GuardianOverrideVote`

**Execution System**
- **Function**: `execute_guardian_rate_limit_override(proposal_id)`
- **Description**: Execute approved proposals that meet threshold
- **Threshold**: Configurable minimum number of guardian votes required
- **Effect**: Clears the active rate limit if executed
- **Event**: `GuardianOverrideExecuted`

### 3. Configurable Multi-Sig Threshold
**Threshold Management**
- **Function**: `set_guardian_threshold(new_threshold)`
- **Access**: Admin only
- **Constraints**: Must be between 1 and total guardian count
- **Purpose**: Allows adjustment of multi-sig requirements based on security needs
- **Event**: `GuardianThresholdChanged`

### 4. Guardian Monitoring and Transparency
**Proposal Monitoring**
- **Function**: `get_guardian_override_proposal(proposal_id)`
- **Returns**: (proposer, votes_for, votes_against, creation_timestamp, executed)
- **Purpose**: Full transparency into proposal status

**Vote Tracking**
- **Function**: `has_guardian_voted(proposal_id, guardian)`
- **Returns**: Boolean indicating if guardian has voted
- **Purpose**: Prevent double voting and track participation

**Threshold Queries**
- **Function**: `guardian_threshold()`
- **Returns**: Current threshold for multi-sig operations
- **Purpose**: Query current governance parameters

## Technical Implementation

### Data Structures
```cairo
#[derive(Drop, Serde, starknet::Store)]
pub struct GuardianOverrideProposal {
    pub proposer: ContractAddress,
    pub votes_for: u32,
    pub votes_against: u32,
    pub creation_timestamp: u64,
    pub executed: bool,
}
```

### Storage Layout
- `guardian_threshold: u32` - Multi-sig threshold
- `guardian_override_proposals: Map<u256, GuardianOverrideProposal>` - Proposal storage
- `guardian_votes: Map<(u256, ContractAddress), bool>` - Vote tracking

### Events
```cairo
GuardianEmergencyPause { guardian, timestamp }
GuardianOverrideProposed { proposal_id, proposer, timestamp }
GuardianOverrideVote { proposal_id, guardian, approve }
GuardianOverrideExecuted { proposal_id, timestamp }
GuardianThresholdChanged { old_threshold, new_threshold }
```

## Security Features

### Access Control
- **Guardian Functions**: Only registered guardians can call guardian-specific functions
- **Admin Functions**: Only admin can modify guardian threshold
- **Proposal Validation**: Extensive checks prevent invalid proposals and double-voting

### Governance Safeguards
- **Threshold Enforcement**: Proposals cannot execute without sufficient votes
- **One-Time Execution**: Proposals can only be executed once
- **Vote Integrity**: Each guardian can only vote once per proposal
- **Transparency**: All actions are logged with events

## Use Cases

### Emergency Response
```cairo
// Guardian detects exploit
circuit_breaker.guardian_emergency_pause();
// System is immediately paused, stopping all operations
```

### Collaborative Override
```cairo
// Guardian 1 proposes override
circuit_breaker.guardian_propose_rate_limit_override(proposal_id);

// Guardian 2 votes in favor  
circuit_breaker.guardian_vote_rate_limit_override(proposal_id, true);

// Guardian 3 votes in favor (meets threshold of 2)
circuit_breaker.guardian_vote_rate_limit_override(proposal_id, true);

// Any guardian executes
circuit_breaker.execute_guardian_rate_limit_override(proposal_id);
// Rate limit is cleared
```

### Threshold Management
```cairo
// Admin adjusts security level
circuit_breaker.set_guardian_threshold(3); // Require 3 out of 5 guardians
```

## Testing Coverage

### Emergency Pause Tests
- ✅ Guardian can trigger emergency pause
- ✅ Non-guardian cannot trigger emergency pause
- ✅ System properly enters paused state

### Multi-Sig Override Tests
- ✅ Complete proposal → vote → execution flow
- ✅ Mixed voting scenarios (some for, some against)
- ✅ Threshold enforcement
- ✅ Vote tracking and double-vote prevention

### Threshold Management Tests
- ✅ Valid threshold updates
- ✅ Invalid threshold rejection (too high, zero)
- ✅ Admin-only access control

### Monitoring Tests
- ✅ Proposal state queries
- ✅ Vote status tracking
- ✅ Threshold queries

## Benefits

1. **Enhanced Security**: Multiple guardians must agree for critical overrides
2. **Decentralized Governance**: Reduces single points of failure
3. **Transparency**: All actions are recorded and queryable
4. **Flexibility**: Configurable thresholds adapt to changing security needs
5. **Emergency Response**: Immediate pause capability for critical situations

## Future Enhancements

Potential future additions could include:
- Time-bounded proposals (automatic expiry)
- Different threshold requirements for different types of operations
- Guardian reputation/staking mechanisms
- Integration with external oracle systems for automated responses