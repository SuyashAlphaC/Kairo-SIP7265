use starknet::{ContractAddress, get_caller_address, get_contract_address, get_block_timestamp};
use openzeppelin_access::ownable::OwnableComponent;
use openzeppelin_security::pausable::PausableComponent;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use openzeppelin_upgrades::UpgradeableComponent;
use starknet::storage::{StoragePointerWriteAccess, StoragePointerReadAccess, Map, StorageMapReadAccess, StorageMapWriteAccess};

// === CORE DATA STRUCTURES ===

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Company {
    positive_pool: u256,
    negative_pool: u256,
    positive_shares: u256,
    negative_shares: u256,
    total_invested: u256,
    reputation_score: i32,
    is_active: bool,
    both_sides_active: bool,
    created_timestamp: u64,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct CompanyMetadata {
    name: felt252,
    description: felt252,
    category: felt252,
    creator: ContractAddress, // Always admin in this case
    created_timestamp: u64,
    is_active: bool,
    total_volume: u256,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct UserPosition {
    company_id: u256,
    positive_shares: u256,
    negative_shares: u256,
    positive_invested: u256,
    negative_invested: u256,
    positive_entry_timestamp: u64,
    negative_entry_timestamp: u64,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub enum PositionSide {
    Positive,
    Negative,
}

// === EVENTS ===

#[derive(Drop, starknet::Event)]
pub struct CompanyCreated {
    #[key]
    company_id: u256,
    name: felt252,
    creator: ContractAddress,
    category: felt252,
}

#[derive(Drop, starknet::Event)]
pub struct InvestmentMade {
    #[key]
    user: ContractAddress,
    #[key]
    company_id: u256,
    side: PositionSide,
    amount: u256,
    shares_received: u256,
    new_positive_price: u256,
    new_negative_price: u256,
    new_reputation_score: i32,
}

#[derive(Drop, starknet::Event)]
pub struct PositionClosed {
    #[key]
    user: ContractAddress,
    #[key]
    company_id: u256,
    side: PositionSide,
    shares_burned: u256,
    payout: u256,
    reputation_score_at_exit: i32,
}

#[derive(Drop, starknet::Event)]
pub struct PriceUpdate {
    #[key]
    company_id: u256,
    positive_price: u256,
    negative_price: u256,
    positive_pool: u256,
    negative_pool: u256,
    reputation_score: i32,
    triggered_by: ContractAddress,
}

#[derive(Drop, starknet::Event)]
pub struct CompanyPaused {
    #[key]
    company_id: u256,
    paused: bool,
}

#[derive(Drop, starknet::Event)]
pub struct FeesCollected {
    recipient: ContractAddress,
    amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct EmergencyAction {
    action_type: felt252,
    executed_by: ContractAddress,
    details: felt252,
}

#[derive(Drop, starknet::Event)]
pub struct ReputationUpdated {
    #[key]
    company_id: u256,
    new_score: i32,
    positive_pool: u256,
    negative_pool: u256,
}

// === MAIN CONTRACT ===

#[starknet::contract]
pub mod CompanyReputationMarket {
    use core::panic_with_felt252;
    use super::{
        Company, CompanyMetadata, UserPosition, PositionSide, CompanyCreated, InvestmentMade, 
        PositionClosed, PriceUpdate, CompanyPaused, FeesCollected, EmergencyAction, ReputationUpdated,
        OwnableComponent, PausableComponent, UpgradeableComponent,
        IERC20Dispatcher, IERC20DispatcherTrait
    };
    use starknet::storage::{StoragePointerWriteAccess, StoragePointerReadAccess, Map, StorageMapReadAccess, StorageMapWriteAccess};
    use starknet::{ContractAddress, get_caller_address, get_contract_address, get_block_timestamp};
    use openzeppelin_access::ownable::OwnableComponent::InternalTrait as OwnableInternalTrait;
    use openzeppelin_security::pausable::PausableComponent::InternalTrait as PausableInternalTrait;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    // Component Mixins
    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;

    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        // Components
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,

        // Core protocol storage
        usdc_token: ContractAddress,
        fee_recipient: ContractAddress,
        platform_fee_bps: u256,
        collected_fees: u256,

        // Company data
        company_counter: u256,
        companies: Map<u256, Company>,
        company_metadata: Map<u256, CompanyMetadata>,
        company_index: Map<u256, u256>, // For enumeration: index -> company_id
        
        // User positions
        user_positions: Map<(ContractAddress, u256), UserPosition>,
        
        // Investment settings and limits
        minimum_investment: u256,
        maximum_investment: u256,
        company_creation_fee: u256,
        minimum_liquidity: u256,
        max_total_pool_size: u256,
        
        // Individual company controls
        paused_companies: Map<u256, bool>,
        company_limits: Map<u256, u256>, // Per-company investment limits
        user_position_limits: Map<(ContractAddress, u256), u256>, // Per-user per-company limits
        
        // Analytics and tracking
        daily_volume: Map<(u256, u64), u256>, // (company_id, day) -> volume
        user_daily_volume: Map<(ContractAddress, u64), u256>, // (user, day) -> volume
        reputation_history: Map<(u256, u64), i32>, // (company_id, day) -> reputation_score
        total_platform_volume: u256,
        total_platform_tvl: u256,
        
        // Emergency controls
        emergency_paused: bool,
        emergency_withdrawal_enabled: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        CompanyCreated: CompanyCreated,
        InvestmentMade: InvestmentMade,
        PositionClosed: PositionClosed,
        PriceUpdate: PriceUpdate,
        CompanyPaused: CompanyPaused,
        FeesCollected: FeesCollected,
        EmergencyAction: EmergencyAction,
        ReputationUpdated: ReputationUpdated,
    }

    // === ERROR CONSTANTS ===
    pub mod Errors {
        pub const INVALID_COMPANY: felt252 = 'Invalid company ID';
        pub const COMPANY_INACTIVE: felt252 = 'Company is inactive';
        pub const COMPANY_PAUSED: felt252 = 'Company is paused';
        pub const ZERO_AMOUNT: felt252 = 'Amount cannot be zero';
        pub const INSUFFICIENT_FUNDS: felt252 = 'Insufficient funds';
        pub const NO_POSITION: felt252 = 'No position to close';
        pub const TRANSFER_FAILED: felt252 = 'Token transfer failed';
        pub const POOL_INTEGRITY: felt252 = 'Pool integrity violation';
        pub const INVESTMENT_TOO_SMALL: felt252 = 'Investment below minimum';
        pub const INVESTMENT_TOO_LARGE: felt252 = 'Investment above maximum';
        pub const EMERGENCY_PAUSED: felt252 = 'Emergency pause active';
        pub const INVALID_PERCENTAGE: felt252 = 'Invalid percentage';
        pub const USER_LIMIT_EXCEEDED: felt252 = 'User limit exceeded';
        pub const COMPANY_LIMIT_EXCEEDED: felt252 = 'Company limit exceeded';
        pub const SLIPPAGE_EXCEEDED: felt252 = 'Slippage tolerance exceeded';
        pub const NOT_ADMIN: felt252 = 'Not admin';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        usdc_token: ContractAddress,
        fee_recipient: ContractAddress,
        platform_fee_bps: u256
    ) {
        self.ownable.initializer(owner);
        self.usdc_token.write(usdc_token);
        self.fee_recipient.write(fee_recipient);
        self.platform_fee_bps.write(platform_fee_bps);
        
        // Set reasonable defaults
        self.minimum_investment.write(1000000); // 1 USDC (6 decimals)
        self.maximum_investment.write(100000000000); // 100,000 USDC
        self.company_counter.write(0);
        self.minimum_liquidity.write(0);
        self.max_total_pool_size.write(0); // 0 = no limit
        self.company_creation_fee.write(0);
        self.total_platform_volume.write(0);
        self.total_platform_tvl.write(0);
        self.emergency_paused.write(false);
        self.emergency_withdrawal_enabled.write(false);
    }

    // === INTERNAL HELPER FUNCTIONS ===

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _get_token(self: @ContractState) -> IERC20Dispatcher {
            IERC20Dispatcher { contract_address: self.usdc_token.read() }
        }

        fn _assert_not_emergency_paused(self: @ContractState) {
            assert(!self.emergency_paused.read(), Errors::EMERGENCY_PAUSED);
        }

        fn _validate_company_exists(self: @ContractState, company_id: u256) {
            assert(company_id > 0 && company_id <= self.company_counter.read(), Errors::INVALID_COMPANY);
            let company = self.companies.read(company_id);
            assert(company.is_active, Errors::COMPANY_INACTIVE);
        }

        fn _validate_company_not_paused(self: @ContractState, company_id: u256) {
            assert(!self.paused_companies.read(company_id), Errors::COMPANY_PAUSED);
        }

        fn _validate_amount(self: @ContractState, amount: u256) {
            assert(amount > 0, Errors::ZERO_AMOUNT);
            assert(amount >= self.minimum_investment.read(), Errors::INVESTMENT_TOO_SMALL);
            assert(amount <= self.maximum_investment.read(), Errors::INVESTMENT_TOO_LARGE);
        }

        fn _validate_percentage(self: @ContractState, percentage: u256) {
            assert(percentage > 0 && percentage <= 10000, Errors::INVALID_PERCENTAGE);
        }

        fn _calculate_reputation_score(self: @ContractState, positive_pool: u256, negative_pool: u256) -> i32 {
            let total_pool = positive_pool + negative_pool;
            if total_pool == 0 {
                return 0;
            }
            
            let hundred = 100_u256;
            let (is_positive, difference) = if positive_pool >= negative_pool {
                (true, positive_pool - negative_pool)
            } else {
                (false, negative_pool - positive_pool)
            };
            
            let score_u256 = (difference * hundred) / total_pool;
            assert(score_u256.high == 0, 'Score calculation overflow');
            
            let score_u128: u128 = score_u256.low;
            let score_i32: i32 = match score_u128.try_into() {
                Option::Some(val) => val,
                Option::None => panic_with_felt252('Score conversion failed')
            };
            
            if is_positive { score_i32 } else { -score_i32 }
        }

        fn _calculate_share_prices(self: @ContractState, positive_pool: u256, negative_pool: u256) -> (u256, u256) {
            let total_pool = positive_pool + negative_pool;
            if total_pool == 0 {
                return (500000, 500000); // 50-50 prices (0.50 each, 6 decimals)
            }

            let positive_price = (positive_pool * 1000000) / total_pool;
            let negative_price = 1000000 - positive_price;
            
            (positive_price, negative_price)
        }

        fn _calculate_shares_from_investment(self: @ContractState, investment_amount: u256, share_price: u256) -> u256 {
            // In constant-sum model, shares = investment amount
            // This maintains the invariant that total shares <= total pool
            investment_amount
        }

        fn _calculate_payout(self: @ContractState, shares: u256, current_price: u256) -> u256 {
            (shares * current_price) / 1000000
        }

        fn _update_analytics(ref self: ContractState, company_id: u256, user: ContractAddress, amount: u256) {
            let day = get_block_timestamp() / 86400;
            
            // Update company daily volume
            let current_company_volume = self.daily_volume.read((company_id, day));
            self.daily_volume.write((company_id, day), current_company_volume + amount);
            
            // Update user daily volume
            let current_user_volume = self.user_daily_volume.read((user, day));
            self.user_daily_volume.write((user, day), current_user_volume + amount);
            
            // Update reputation history
            let company = self.companies.read(company_id);
            self.reputation_history.write((company_id, day), company.reputation_score);
            
            // Update platform metrics
            self.total_platform_volume.write(self.total_platform_volume.read() + amount);
            
            // Update company metadata volume
            let mut metadata = self.company_metadata.read(company_id);
            metadata.total_volume = metadata.total_volume + amount;
            self.company_metadata.write(company_id, metadata);
        }

        fn _validate_pool_integrity(self: @ContractState, company: Company) {
            assert(company.positive_shares <= company.positive_pool, Errors::POOL_INTEGRITY);
            assert(company.negative_shares <= company.negative_pool, Errors::POOL_INTEGRITY);
        }

        fn _validate_limits(self: @ContractState, company_id: u256, user: ContractAddress, amount: u256, is_positive: bool) {
            // Check company-specific limits
            let company_limit = self.company_limits.read(company_id);
            if company_limit > 0 {
                assert(amount <= company_limit, Errors::COMPANY_LIMIT_EXCEEDED);
            }
            
            // Check user position limits
            let user_limit = self.user_position_limits.read((user, company_id));
            if user_limit > 0 {
                let position = self.user_positions.read((user, company_id));
                let current_invested = if is_positive { position.positive_invested } else { position.negative_invested };
                assert(current_invested + amount <= user_limit, Errors::USER_LIMIT_EXCEEDED);
            }
            
            // Check total pool size limit
            let max_pool = self.max_total_pool_size.read();
            if max_pool > 0 {
                let company = self.companies.read(company_id);
                let total_after = company.positive_pool + company.negative_pool + amount;
                assert(total_after <= max_pool, 'Pool size limit exceeded');
            }
        }

        fn _recalculate_tvl(ref self: ContractState) {
            let mut total_tvl = 0_u256;
            let company_count = self.company_counter.read();
            let mut i = 1_u256;
            
            loop {
                if i > company_count { break; }
                let company = self.companies.read(i);
                total_tvl += company.positive_pool + company.negative_pool;
                i += 1;
            }
            
            self.total_platform_tvl.write(total_tvl);
        }

        fn _update_company_score_and_emit(ref self: ContractState, company_id: u256, mut company: Company) -> Company {
            company.reputation_score = self._calculate_reputation_score(company.positive_pool, company.negative_pool);
            self.companies.write(company_id, company);
            
            self.emit(ReputationUpdated {
                company_id,
                new_score: company.reputation_score,
                positive_pool: company.positive_pool,
                negative_pool: company.negative_pool,
            });
            
            company
        }
    }

    // === PUBLIC INTERFACE ===

    #[abi(embed_v0)]
    impl CompanyReputationMarketImpl of super::ICompanyReputationMarket<ContractState> {
        
        // === CORE COMPANY FUNCTIONS ===
        
        fn create_company(ref self: ContractState, name: felt252, category: felt252, description: felt252) -> u256 {
            // Only admin can create companies
            self.ownable.assert_only_owner();
            self.pausable.assert_not_paused();
            self._assert_not_emergency_paused();
            
            let creator = get_caller_address(); // Will be admin
            
            // Handle creation fee if set
            let creation_fee = self.company_creation_fee.read();
            if creation_fee > 0 {
                let token = self._get_token();
                assert(
                    token.transfer_from(creator, get_contract_address(), creation_fee),
                    Errors::TRANSFER_FAILED
                );
                self.collected_fees.write(self.collected_fees.read() + creation_fee);
            }

            // Create new company
            let company_id = self.company_counter.read() + 1;
            self.company_counter.write(company_id);
            self.company_index.write(company_id, company_id);

            let current_timestamp = get_block_timestamp();
            let company = Company {
                positive_pool: 0,
                negative_pool: 0,
                positive_shares: 0,
                negative_shares: 0,
                total_invested: 0,
                reputation_score: 0,
                is_active: true,
                both_sides_active: false,
                created_timestamp: current_timestamp,
            };

            let metadata = CompanyMetadata {
                name,
                creator,
                created_timestamp: current_timestamp,
                category,
                is_active: true,
                description,
                total_volume: 0,
            };

            self.companies.write(company_id, company);
            self.company_metadata.write(company_id, metadata);

            self.emit(CompanyCreated { 
                company_id, 
                name, 
                creator, 
                category 
            });

            company_id
        }

        fn invest_in_company(ref self: ContractState, company_id: u256, side: PositionSide, amount: u256) {
            self._invest_with_slippage(company_id, side, amount, 0)
        }

        fn invest_with_slippage(ref self: ContractState, company_id: u256, side: PositionSide, amount: u256, min_shares: u256) {
            self._invest_with_slippage(company_id, side, amount, min_shares)
        }

        fn withdraw_position(ref self: ContractState, company_id: u256, side: PositionSide, percentage: u256) {
            self.pausable.assert_not_paused();
            self._assert_not_emergency_paused();
            self._validate_company_exists(company_id);
            self._validate_company_not_paused(company_id);
            self._validate_percentage(percentage);

            let caller = get_caller_address();
            let position_key = (caller, company_id);
            let mut position = self.user_positions.read(position_key);
            let mut company = self.companies.read(company_id);

            let (shares_to_burn, _current_invested) = match side {
                PositionSide::Positive => {
                    assert(position.positive_shares > 0, Errors::NO_POSITION);
                    let shares = (position.positive_shares * percentage) / 10000;
                    (shares, position.positive_invested)
                },
                PositionSide::Negative => {
                    assert(position.negative_shares > 0, Errors::NO_POSITION);
                    let shares = (position.negative_shares * percentage) / 10000;
                    (shares, position.negative_invested)
                },
            };

            // Calculate current prices based on reputation (pool distribution)
            let (pos_price, neg_price) = self._calculate_share_prices(company.positive_pool, company.negative_pool);
            
            // Calculate payout based on current reputation-driven prices
            let payout = match side {
                PositionSide::Positive => self._calculate_payout(shares_to_burn, pos_price),
                PositionSide::Negative => self._calculate_payout(shares_to_burn, neg_price),
            };

            // Update company pools and shares
            match side {
                PositionSide::Positive => {
                    assert(company.positive_pool >= payout, Errors::INSUFFICIENT_FUNDS);
                    company.positive_pool -= payout;
                    company.positive_shares -= shares_to_burn;
                    position.positive_shares -= shares_to_burn;
                    
                    if percentage == 10000 {
                        position.positive_invested = 0;
                        position.positive_entry_timestamp = 0;
                    } else {
                        position.positive_invested = (position.positive_invested * (10000 - percentage)) / 10000;
                    }
                },
                PositionSide::Negative => {
                    assert(company.negative_pool >= payout, Errors::INSUFFICIENT_FUNDS);
                    company.negative_pool -= payout;
                    company.negative_shares -= shares_to_burn;
                    position.negative_shares -= shares_to_burn;
                    
                    if percentage == 10000 {
                        position.negative_invested = 0;
                        position.negative_entry_timestamp = 0;
                    } else {
                        position.negative_invested = (position.negative_invested * (10000 - percentage)) / 10000;
                    }
                },
            }

            // Update company state
            if company.positive_pool == 0 || company.negative_pool == 0 {
                company.both_sides_active = false;
            }
            
            // Update reputation score after withdrawal
            company = self._update_company_score_and_emit(company_id, company);

            // Transfer payout
            let token = self._get_token();
            assert(token.transfer(caller, payout), Errors::TRANSFER_FAILED);

            // Store updates
            self.user_positions.write(position_key, position);
            self._recalculate_tvl();

            // Calculate new prices and emit events
            let (new_pos_price, new_neg_price) = self._calculate_share_prices(company.positive_pool, company.negative_pool);

            self.emit(PositionClosed {
                user: caller,
                company_id,
                side,
                shares_burned: shares_to_burn,
                payout,
                reputation_score_at_exit: company.reputation_score,
            });

            self.emit(PriceUpdate {
                company_id,
                positive_price: new_pos_price,
                negative_price: new_neg_price,
                positive_pool: company.positive_pool,
                negative_pool: company.negative_pool,
                reputation_score: company.reputation_score,
                triggered_by: caller,
            });
        }

        // === VIEW FUNCTIONS ===
        
        fn get_company(self: @ContractState, company_id: u256) -> Company {
            self._validate_company_exists(company_id);
            self.companies.read(company_id)
        }

        fn get_company_metadata(self: @ContractState, company_id: u256) -> CompanyMetadata {
            self._validate_company_exists(company_id);
            self.company_metadata.read(company_id)
        }

        fn get_share_prices(self: @ContractState, company_id: u256) -> (u256, u256) {
            self._validate_company_exists(company_id);
            let company = self.companies.read(company_id);
            self._calculate_share_prices(company.positive_pool, company.negative_pool)
        }

        fn get_user_position(self: @ContractState, user: ContractAddress, company_id: u256) -> UserPosition {
            self._validate_company_exists(company_id);
            self.user_positions.read((user, company_id))
        }

        fn get_position_value(self: @ContractState, user: ContractAddress, company_id: u256) -> (u256, u256) {
            self._validate_company_exists(company_id);
            let position = self.user_positions.read((user, company_id));
            let (pos_price, neg_price) = self.get_share_prices(company_id);
            
            let positive_value = self._calculate_payout(position.positive_shares, pos_price);
            let negative_value = self._calculate_payout(position.negative_shares, neg_price);
            
            (positive_value, negative_value)
        }

        fn get_reputation_score(self: @ContractState, company_id: u256) -> i32 {
            self._validate_company_exists(company_id);
            let company = self.companies.read(company_id);
            company.reputation_score
        }

        // === COMPANY DISCOVERY FUNCTIONS ===
        
        fn get_all_companies(self: @ContractState) -> Array<u256> {
            let mut companies: Array<u256> = ArrayTrait::new();
            let count = self.company_counter.read();
            let mut i = 1_u256;
            
            loop {
                if i > count { break; }
                companies.append(i);
                i += 1;
            }
            
            companies
        }

        fn get_active_companies(self: @ContractState) -> Array<u256> {
            let mut active_companies: Array<u256> = ArrayTrait::new();
            let count = self.company_counter.read();
            let mut i = 1_u256;
            
            loop {
                if i > count { break; }
                let company = self.companies.read(i);
                if company.is_active {
                    active_companies.append(i);
                }
                i += 1;
            }
            
            active_companies
        }

        fn get_companies_with_activity(self: @ContractState) -> Array<u256> {
            let mut active_companies: Array<u256> = ArrayTrait::new();
            let count = self.company_counter.read();
            let mut i = 1_u256;
            
            loop {
                if i > count { break; }
                let company = self.companies.read(i);
                if company.total_invested > 0 {
                    active_companies.append(i);
                }
                i += 1;
            }
            
            active_companies
        }

        fn get_active_companies_count(self: @ContractState) -> u256 {
            let mut count = 0_u256;
            let total_companies = self.company_counter.read();
            let mut i = 1_u256;
            
            loop {
                if i > total_companies { break; }
                let company = self.companies.read(i);
                if company.is_active {
                    count += 1;
                }
                i += 1;
            }
            
            count
        }

        // === USER PORTFOLIO FUNCTIONS ===
        
        fn get_user_total_portfolio_value(self: @ContractState, user: ContractAddress) -> u256 {
            let mut total_value = 0_u256;
            let count = self.company_counter.read();
            let mut i = 1_u256;
            
            loop {
                if i > count { break; }
                let position = self.user_positions.read((user, i));
                if position.positive_shares > 0 || position.negative_shares > 0 {
                    let (pos_val, neg_val) = self.get_position_value(user, i);
                    total_value += pos_val + neg_val;
                }
                i += 1;
            }
            
            total_value
        }

        fn get_user_position_count(self: @ContractState, user: ContractAddress) -> u256 {
            let mut count = 0_u256;
            let total_companies = self.company_counter.read();
            let mut i = 1_u256;
            
            loop {
                if i > total_companies { break; }
                let position = self.user_positions.read((user, i));
                if position.positive_shares > 0 || position.negative_shares > 0 {
                    count += 1;
                }
                i += 1;
            }
            
            count
        }

        fn get_user_profit_loss(self: @ContractState, user: ContractAddress, company_id: u256) -> (u256, bool, u256, bool) {
            self._validate_company_exists(company_id);
            let position = self.user_positions.read((user, company_id));
            let (pos_value, neg_value) = self.get_position_value(user, company_id);
            
            // Calculate P&L based on current reputation-driven prices
            let (pos_amount, pos_is_profit) = if pos_value >= position.positive_invested {
                (pos_value - position.positive_invested, true)
            } else {
                (position.positive_invested - pos_value, false)
            };
            
            let (neg_amount, neg_is_profit) = if neg_value >= position.negative_invested {
                (neg_value - position.negative_invested, true)
            } else {
                (position.negative_invested - neg_value, false)
            };
            
            (pos_amount, pos_is_profit, neg_amount, neg_is_profit)
        }

        fn get_detailed_position_value(self: @ContractState, user: ContractAddress, company_id: u256) -> (u256, u256, u256, u256, u256, u256) {
            self._validate_company_exists(company_id);
            let position = self.user_positions.read((user, company_id));
            let (pos_value, neg_value) = self.get_position_value(user, company_id);
            
            // Returns: (pos_shares, pos_value, pos_invested, neg_shares, neg_value, neg_invested)
            (position.positive_shares, pos_value, position.positive_invested, 
             position.negative_shares, neg_value, position.negative_invested)
        }

        // === ANALYTICS FUNCTIONS ===
        
        fn get_24h_volume(self: @ContractState, company_id: u256) -> u256 {
            self._validate_company_exists(company_id);
            let day = get_block_timestamp() / 86400;
            self.daily_volume.read((company_id, day))
        }

        fn get_reputation_trend(self: @ContractState, company_id: u256, days: u64) -> Array<i32> {
            self._validate_company_exists(company_id);
            let mut trend: Array<i32> = ArrayTrait::new();
            let current_day = get_block_timestamp() / 86400;
            let mut i = 0_u64;
            
            loop {
                if i >= days { break; }
                let day = current_day - (days - 1 - i);
                let score = self.reputation_history.read((company_id, day));
                trend.append(score);
                i += 1;
            }
            
            trend
        }

        fn get_platform_total_volume(self: @ContractState) -> u256 {
            self.total_platform_volume.read()
        }

        fn get_platform_tvl(self: @ContractState) -> u256 {
            self.total_platform_tvl.read()
        }

        fn get_company_depth(self: @ContractState, company_id: u256) -> (u256, u256, u256, u256) {
            self._validate_company_exists(company_id);
            let company = self.companies.read(company_id);
            let (pos_price, neg_price) = self._calculate_share_prices(company.positive_pool, company.negative_pool);
            
            // Calculate depth (rough estimate of liquidity)
            let pos_depth = if company.positive_pool > 0 { company.positive_pool / 100 } else { 0 };
            let neg_depth = if company.negative_pool > 0 { company.negative_pool / 100 } else { 0 };
            
            (pos_price, neg_price, pos_depth, neg_depth)
        }

        // === PREDICTION/SIMULATION FUNCTIONS ===
        
        fn simulate_investment_impact(self: @ContractState, company_id: u256, side: PositionSide, amount: u256) -> (u256, u256, i32) {
            self._validate_company_exists(company_id);
            let company = self.companies.read(company_id);
            
            // Calculate net amount after fees
            let fee = (amount * self.platform_fee_bps.read()) / 10000;
            let net_amount = amount - fee;
            
            let (new_pos_pool, new_neg_pool) = match side {
                PositionSide::Positive => (company.positive_pool + net_amount, company.negative_pool),
                PositionSide::Negative => (company.positive_pool, company.negative_pool + net_amount),
            };
            
            let (new_prices_0, new_prices_1) = self._calculate_share_prices(new_pos_pool, new_neg_pool);
            let new_reputation = self._calculate_reputation_score(new_pos_pool, new_neg_pool);
            
            (new_prices_0, new_prices_1, new_reputation)
        }

        fn get_expected_shares(self: @ContractState, company_id: u256, side: PositionSide, amount: u256) -> u256 {
            self._validate_company_exists(company_id);
            // Calculate fee first
            let fee = (amount * self.platform_fee_bps.read()) / 10000;
            let net_amount = amount - fee;
    
            // In constant-sum model, shares = net investment
            net_amount
        }

        fn calculate_price_impact(self: @ContractState, company_id: u256, amount: u256, is_positive: bool) -> u256 {
            self._validate_company_exists(company_id);
            let company = self.companies.read(company_id);
            let current_pool = if is_positive { company.positive_pool } else { company.negative_pool };
            
            if current_pool == 0 {
                return 10000; // 100% impact
            }
            
            // Price impact in basis points
            (amount * 10000) / (current_pool + amount)
        }

        fn get_expected_payout(self: @ContractState, company_id: u256, amount: u256, is_positive: bool) -> u256 {
            self._validate_company_exists(company_id);
            let company = self.companies.read(company_id);
            
            // Calculate fee
            let fee = (amount * self.platform_fee_bps.read()) / 10000;
            let net_amount = amount - fee;
            let shares = net_amount; // In constant-sum model
            
            // Simulate company after investment
            let new_pos_pool = if is_positive { company.positive_pool + net_amount } else { company.positive_pool };
            let new_neg_pool = if is_positive { company.negative_pool } else { company.negative_pool + net_amount };
            let (new_pos_price, new_neg_price) = self._calculate_share_prices(new_pos_pool, new_neg_pool);
            
            let new_price = if is_positive { new_pos_price } else { new_neg_price };
            self._calculate_payout(shares, new_price)
        }

        // === ADMIN FUNCTIONS ===
        
        fn set_platform_fee(ref self: ContractState, fee_bps: u256) {
            self.ownable.assert_only_owner();
            assert(fee_bps <= 1000, 'Fee too high'); // Max 10%
            self.platform_fee_bps.write(fee_bps);
        }

        fn set_fee_recipient(ref self: ContractState, new_recipient: ContractAddress) {
            self.ownable.assert_only_owner();
            self.fee_recipient.write(new_recipient);
        }

        fn set_investment_limits(ref self: ContractState, min_investment: u256, max_investment: u256) {
            self.ownable.assert_only_owner();
            assert(min_investment > 0 && max_investment > min_investment, 'Invalid limits');
            self.minimum_investment.write(min_investment);
            self.maximum_investment.write(max_investment);
        }

        fn set_company_limits(ref self: ContractState, min_liquidity: u256, creation_fee: u256, max_pool_size: u256) {
            self.ownable.assert_only_owner();
            self.minimum_liquidity.write(min_liquidity);
            self.company_creation_fee.write(creation_fee);
            self.max_total_pool_size.write(max_pool_size);
        }

        fn set_usdc_token(ref self: ContractState, new_token: ContractAddress) {
            self.ownable.assert_only_owner();
            self.usdc_token.write(new_token);
        }

        fn pause_company(ref self: ContractState, company_id: u256, paused: bool) {
            self.ownable.assert_only_owner();
            self._validate_company_exists(company_id);
            self.paused_companies.write(company_id, paused);
            
            self.emit(CompanyPaused { company_id, paused });
        }

        fn set_company_active_status(ref self: ContractState, company_id: u256, is_active: bool) {
            self.ownable.assert_only_owner();
            self._validate_company_exists(company_id);
            let mut company = self.companies.read(company_id);
            company.is_active = is_active;
            self.companies.write(company_id, company);
            
            let mut metadata = self.company_metadata.read(company_id);
            metadata.is_active = is_active;
            self.company_metadata.write(company_id, metadata);
        }

        fn set_user_position_limit(ref self: ContractState, user: ContractAddress, company_id: u256, limit: u256) {
            self.ownable.assert_only_owner();
            self._validate_company_exists(company_id);
            self.user_position_limits.write((user, company_id), limit);
        }

        fn set_company_investment_limit(ref self: ContractState, company_id: u256, limit: u256) {
            self.ownable.assert_only_owner();
            self._validate_company_exists(company_id);
            self.company_limits.write(company_id, limit);
        }

        fn collect_fees(ref self: ContractState) {
            self.ownable.assert_only_owner();
            let amount = self.collected_fees.read();
            if amount > 0 {
                self.collected_fees.write(0);
                let token = self._get_token();
                assert(
                    token.transfer(self.fee_recipient.read(), amount),
                    Errors::TRANSFER_FAILED
                );
                
                self.emit(FeesCollected { 
                    recipient: self.fee_recipient.read(), 
                    amount 
                });
            }
        }

        // === EMERGENCY FUNCTIONS ===
        
        fn emergency_pause_all(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.emergency_paused.write(true);
            self.pausable.pause();
            
            self.emit(EmergencyAction {
                action_type: 'EMERGENCY_PAUSE_ALL',
                executed_by: get_caller_address(),
                details: 'All operations paused'
            });
        }

        fn emergency_unpause_all(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.emergency_paused.write(false);
            self.pausable.unpause();
            
            self.emit(EmergencyAction {
                action_type: 'EMERGENCY_UNPAUSE_ALL',
                executed_by: get_caller_address(),
                details: 'All operations resumed'
            });
        }

        fn emergency_withdraw_stuck_funds(ref self: ContractState, recipient: ContractAddress, amount: u256) {
            self.ownable.assert_only_owner();
            assert(self.emergency_withdrawal_enabled.read(), 'Emergency withdrawal disabled');
            
            let token = self._get_token();
            assert(token.transfer(recipient, amount), Errors::TRANSFER_FAILED);
            
            self.emit(EmergencyAction {
                action_type: 'EMERGENCY_WITHDRAWAL',
                executed_by: get_caller_address(),
                details: 'Stuck funds recovered'
            });
        }

        fn enable_emergency_withdrawal(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.emergency_withdrawal_enabled.write(true);
            
            self.emit(EmergencyAction {
                action_type: 'EMERGENCY_WITHDRAWAL_ENABLED',
                executed_by: get_caller_address(),
                details: 'Emergency withdrawal enabled'
            });
        }

        fn pause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.pausable.pause();
        }

        fn unpause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.pausable.unpause();
        }

        // === DEBUG AND TESTING FUNCTIONS ===
        
        fn debug_pool_state(self: @ContractState, company_id: u256) -> (u256, u256, u256, u256) {
            self._validate_company_exists(company_id);
            let company = self.companies.read(company_id);
            (company.positive_pool, company.negative_pool, company.positive_shares, company.negative_shares)
        }

        fn check_pool_solvency(self: @ContractState, company_id: u256) -> bool {
            self._validate_company_exists(company_id);
            let company = self.companies.read(company_id);
            company.positive_shares <= company.positive_pool && company.negative_shares <= company.negative_pool
        }

        fn get_company_info(self: @ContractState, company_id: u256) -> (felt252, ContractAddress, u64, bool, u256) {
            self._validate_company_exists(company_id);
            let metadata = self.company_metadata.read(company_id);
            let company = self.companies.read(company_id);
            (metadata.name, metadata.creator, metadata.created_timestamp, metadata.is_active, metadata.total_volume)
        }

        fn calculate_reputation_score(self: @ContractState, company_id: u256) -> i32 {
            self._validate_company_exists(company_id);
            let company = self.companies.read(company_id);
            self._calculate_reputation_score(company.positive_pool, company.negative_pool)
        }

        fn get_current_position_value(self: @ContractState, user: ContractAddress, company_id: u256) -> (u256, u256) {
            self.get_position_value(user, company_id)
        }
    
    // === INTERNAL INVESTMENT FUNCTION ===
       
    fn _invest_with_slippage(ref self: ContractState, company_id: u256, side: PositionSide, amount: u256, min_shares: u256) {
        self.pausable.assert_not_paused();
        self._assert_not_emergency_paused();
        self._validate_company_exists(company_id);
        self._validate_company_not_paused(company_id);
        self._validate_amount(amount);

        let caller = get_caller_address();
        self._validate_limits(company_id, caller, amount, match side {
            PositionSide::Positive => true,
            PositionSide::Negative => false,
        });

        let mut company = self.companies.read(company_id);
        
        // Calculate platform fee
        let fee = (amount * self.platform_fee_bps.read()) / 10000;
        let net_amount = amount - fee;

        // Transfer tokens
        let token = self._get_token();
        assert(
            token.transfer_from(caller, get_contract_address(), amount),
            Errors::TRANSFER_FAILED
        );

        if fee > 0 {
            self.collected_fees.write(self.collected_fees.read() + fee);
        }

        // Calculate current share prices based on reputation
        let (pos_price, neg_price) = self._calculate_share_prices(company.positive_pool, company.negative_pool);
        
        // Determine price user pays based on side
        let _share_price = match side {
            PositionSide::Positive => pos_price,
            PositionSide::Negative => neg_price,
        };

        // In constant-sum model, shares received = net amount invested
        // This ensures pool integrity: total_shares <= total_pool
        let shares_received = net_amount;

        // Slippage protection (if needed)
        if min_shares > 0 {
            assert(shares_received >= min_shares, Errors::SLIPPAGE_EXCEEDED);
        }

        // Update company pools and shares
        match side {
            PositionSide::Positive => {
                company.positive_pool += net_amount;
                company.positive_shares += shares_received;
            },
            PositionSide::Negative => {
                company.negative_pool += net_amount;
                company.negative_shares += shares_received;
            },
        }

        // Update company activity status
        if !company.both_sides_active && company.positive_pool > 0 && company.negative_pool > 0 {
            company.both_sides_active = true;
        }

        company.total_invested += net_amount;
        
        // Update reputation score based on new pool distribution
        company = self._update_company_score_and_emit(company_id, company);

        // Update user position
        let position_key = (caller, company_id);
        let mut position = self.user_positions.read(position_key);
        
        if position.company_id == 0 {
            position.company_id = company_id;
        }

        let current_time = get_block_timestamp();
        match side {
            PositionSide::Positive => {
                position.positive_shares += shares_received;
                position.positive_invested += net_amount;
                if position.positive_entry_timestamp == 0 {
                    position.positive_entry_timestamp = current_time;
                }
            },
            PositionSide::Negative => {
                position.negative_shares += shares_received;
                position.negative_invested += net_amount;
                if position.negative_entry_timestamp == 0 {
                    position.negative_entry_timestamp = current_time;
                }
            },
        }

        // Validate pool integrity
        self._validate_pool_integrity(company);

        // Store updates
        self.user_positions.write(position_key, position);

        // Update analytics
        self._update_analytics(company_id, caller, net_amount);
        self._recalculate_tvl();

        // Calculate new prices after the investment
        let (new_pos_price, new_neg_price) = self._calculate_share_prices(
            company.positive_pool, 
            company.negative_pool
        );

        // Emit events
        self.emit(InvestmentMade {
            user: caller,
            company_id,
            side,
            amount: net_amount,
            shares_received,
            new_positive_price: new_pos_price,
            new_negative_price: new_neg_price,
            new_reputation_score: company.reputation_score,
        });

        self.emit(PriceUpdate {
            company_id,
            positive_price: new_pos_price,
            negative_price: new_neg_price,
            positive_pool: company.positive_pool,
            negative_pool: company.negative_pool,
            reputation_score: company.reputation_score,
            triggered_by: caller,
        });
    }
    }
}


// === INTERFACE DEFINITION ===

#[starknet::interface]
pub trait ICompanyReputationMarket<TContractState> {
    // Core functions - Admin only creates companies
    fn create_company(ref self: TContractState, name: felt252, category: felt252, description: felt252) -> u256;
    
    // User investment functions
    fn invest_in_company(ref self: TContractState, company_id: u256, side: PositionSide, amount: u256);
    fn invest_with_slippage(ref self: TContractState, company_id: u256, side: PositionSide, amount: u256, min_shares: u256);
    fn _invest_with_slippage(ref self: TContractState, company_id: u256, side: PositionSide, amount: u256, min_shares: u256);
    fn withdraw_position(ref self: TContractState, company_id: u256, side: PositionSide, percentage: u256);
    
    // View functions
    fn get_company(self: @TContractState, company_id: u256) -> Company;
    fn get_company_metadata(self: @TContractState, company_id: u256) -> CompanyMetadata;
    fn get_share_prices(self: @TContractState, company_id: u256) -> (u256, u256);
    fn get_reputation_score(self: @TContractState, company_id: u256) -> i32;
    fn get_user_position(self: @TContractState, user: ContractAddress, company_id: u256) -> UserPosition;
    fn get_position_value(self: @TContractState, user: ContractAddress, company_id: u256) -> (u256, u256);
    
    // Company discovery
    fn get_all_companies(self: @TContractState) -> Array<u256>;
    fn get_active_companies(self: @TContractState) -> Array<u256>;
    fn get_companies_with_activity(self: @TContractState) -> Array<u256>;
    fn get_active_companies_count(self: @TContractState) -> u256;
    
    // User portfolio
    fn get_user_total_portfolio_value(self: @TContractState, user: ContractAddress) -> u256;
    fn get_user_position_count(self: @TContractState, user: ContractAddress) -> u256;
    fn get_user_profit_loss(self: @TContractState, user: ContractAddress, company_id: u256) -> (u256, bool, u256, bool);
    fn get_detailed_position_value(self: @TContractState, user: ContractAddress, company_id: u256) -> (u256, u256, u256, u256, u256, u256);
    
    // Analytics
    fn get_24h_volume(self: @TContractState, company_id: u256) -> u256;
    fn get_reputation_trend(self: @TContractState, company_id: u256, days: u64) -> Array<i32>;
    fn get_platform_total_volume(self: @TContractState) -> u256;
    fn get_platform_tvl(self: @TContractState) -> u256;
    fn get_company_depth(self: @TContractState, company_id: u256) -> (u256, u256, u256, u256);
    
    // Simulation/prediction functions
    fn simulate_investment_impact(self: @TContractState, company_id: u256, side: PositionSide, amount: u256) -> (u256, u256, i32);
    fn get_expected_shares(self: @TContractState, company_id: u256, side: PositionSide, amount: u256) -> u256;
    fn calculate_price_impact(self: @TContractState, company_id: u256, amount: u256, is_positive: bool) -> u256;
    fn get_expected_payout(self: @TContractState, company_id: u256, amount: u256, is_positive: bool) -> u256;
    
    // Admin functions
    fn set_platform_fee(ref self: TContractState, fee_bps: u256);
    fn set_fee_recipient(ref self: TContractState, new_recipient: ContractAddress);
    fn set_investment_limits(ref self: TContractState, min_investment: u256, max_investment: u256);
    fn set_company_limits(ref self: TContractState, min_liquidity: u256, creation_fee: u256, max_pool_size: u256);
    fn set_usdc_token(ref self: TContractState, new_token: ContractAddress);
    fn pause_company(ref self: TContractState, company_id: u256, paused: bool);
    fn set_company_active_status(ref self: TContractState, company_id: u256, is_active: bool);
    fn set_user_position_limit(ref self: TContractState, user: ContractAddress, company_id: u256, limit: u256);
    fn set_company_investment_limit(ref self: TContractState, company_id: u256, limit: u256);
    fn collect_fees(ref self: TContractState);
    
    // Emergency functions
    fn emergency_pause_all(ref self: TContractState);
    fn emergency_unpause_all(ref self: TContractState);
    fn emergency_withdraw_stuck_funds(ref self: TContractState, recipient: ContractAddress, amount: u256);
    fn enable_emergency_withdrawal(ref self: TContractState);
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
    
    // Debug and testing functions
    fn debug_pool_state(self: @TContractState, company_id: u256) -> (u256, u256, u256, u256);
    fn check_pool_solvency(self: @TContractState, company_id: u256) -> bool;
    fn get_company_info(self: @TContractState, company_id: u256) -> (felt252, ContractAddress, u64, bool, u256);
    fn calculate_reputation_score(self: @TContractState, company_id: u256) -> i32;
    fn get_current_position_value(self: @TContractState, user: ContractAddress, company_id: u256) -> (u256, u256);
}