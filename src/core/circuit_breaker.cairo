// src/core/circuit_breaker.cairo

use starknet::{ContractAddress, get_caller_address, get_contract_address, get_block_timestamp};
use openzeppelin_access::ownable::OwnableComponent;
use openzeppelin_security::pausable::PausableComponent;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use starknet::storage::{StoragePointerWriteAccess, StoragePointerReadAccess, Map, StorageMapReadAccess, StorageMapWriteAccess};

#[derive(Drop, starknet::Event)]
    pub struct AssetRegistered {
        #[key]
        pub asset: ContractAddress,
        pub metric_threshold: u256,
        pub min_amount_to_limit: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AssetInflow {
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AssetRateLimitBreached {
        #[key]
        pub asset: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AssetWithdraw {
        #[key]
        pub asset: ContractAddress,
        #[key]
        pub recipient: ContractAddress,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct LockedFundsClaimed {
        #[key]
        pub asset: ContractAddress,
        #[key]
        pub recipient: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AdminSet {
        #[key]
        pub new_admin: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct GracePeriodStarted {
        pub grace_period_end: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TokenBacklogCleaned {
        #[key]
        pub token: ContractAddress,
        pub timestamp: u64,
    }


#[starknet::contract]
pub mod CircuitBreaker {
    use core::panic_with_felt252;
    use core::num::traits::Zero;
    use starknet::{
        ContractAddress, get_caller_address, get_block_timestamp,
        get_contract_address, contract_address_const
    };
    use starknet::storage::{
        Map, StoragePointerReadAccess, StoragePointerWriteAccess, 
        StorageMapReadAccess, StorageMapWriteAccess
    };
    use super::{OwnableComponent, PausableComponent,
        IERC20Dispatcher, IERC20DispatcherTrait, AssetInflow, AssetRegistered, AssetRateLimitBreached, AssetWithdraw, LockedFundsClaimed, TokenBacklogCleaned, GracePeriodStarted, AdminSet};
    use crate::interfaces::circuit_breaker_interface::ICircuitBreaker;
    use crate::types::structs::{Limiter, LiqChangeNode, SignedU256, LimitStatus, SignedU256Trait};
    use crate::utils::limiter_lib::{LimiterLibTrait, LimiterLibImpl};
    use openzeppelin_access::ownable::OwnableComponent::InternalTrait as OwnableInternalTrait;
    use openzeppelin_security::PausableComponent::InternalTrait as PausableInternalTrait;

   // #[abi(embed_v0)]
    //impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;
    //impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    // Components
    //component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    
    // Ownable Mixin
    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    // Pausable
    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;


    #[storage]
    struct Storage {
        //#[substorage(v0)]
       // erc20: ERC20Component::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        
        token_limiters: Map<ContractAddress, Limiter>,
        locked_funds: Map<(ContractAddress, ContractAddress), u256>, // (recipient, asset) -> amount
        list_nodes: Map<(ContractAddress, u64), LiqChangeNode>, // (token, timestamp) -> node
        is_protected_contract: Map<ContractAddress, bool>,
        
        admin: ContractAddress,
        is_rate_limited: bool,
        rate_limit_cooldown_period: u64,
        last_rate_limit_timestamp: u64,
        grace_period_end_timestamp: u64,
        withdrawal_period: u64,
        tick_length: u64,
        native_address_proxy: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        //#[flat]
        //ERC20Event: ERC20Component::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        AssetRegistered: AssetRegistered,
        AssetInflow: AssetInflow,
        AssetRateLimitBreached: AssetRateLimitBreached,
        AssetWithdraw: AssetWithdraw,
        LockedFundsClaimed: LockedFundsClaimed,
        AdminSet: AdminSet,
        GracePeriodStarted: GracePeriodStarted,
        TokenBacklogCleaned: TokenBacklogCleaned,
    }

    
    pub mod Errors {
        pub const NOT_A_PROTECTED_CONTRACT: felt252 = 'Not a protected contract';
        pub const NOT_ADMIN: felt252 = 'Not admin';
        pub const INVALID_ADMIN_ADDRESS: felt252 = 'Invalid admin address';
        pub const NO_LOCKED_FUNDS: felt252 = 'No locked funds';
        pub const RATE_LIMITED: felt252 = 'Rate limited';
        pub const NOT_RATE_LIMITED: felt252 = 'Not rate limited';
        pub const COOLDOWN_PERIOD_NOT_REACHED: felt252 = 'Cooldown period not reached';
        pub const INVALID_GRACE_PERIOD_END: felt252 = 'Invalid grace period end';
        pub const PROTOCOL_WAS_EXPLOITED: felt252 = 'Protocol was exploited';
        pub const NOT_EXPLOITED: felt252 = 'Not exploited';
        pub const NATIVE_TRANSFER_FAILED: felt252 = 'Native transfer failed';
        pub const INVALID_RECIPIENT_ADDRESS: felt252 = 'Invalid recipient address';
        pub const INSUFFICIENT_BALANCE: felt252 = 'Insufficient balance';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        rate_limit_cooldown_period: u64,
        withdrawal_period: u64,
        tick_length: u64
    ) {
        self.admin.write(admin);
        self.ownable.initializer(admin);
        self.rate_limit_cooldown_period.write(rate_limit_cooldown_period);
        self.withdrawal_period.write(withdrawal_period);
        self.tick_length.write(tick_length);
        self.is_rate_limited.write(false);
        
        // Use address(1) as proxy for native token
        self.native_address_proxy.write(contract_address_const::<1>());
    }

    #[abi(embed_v0)]
    impl CircuitBreakerImpl of ICircuitBreaker<ContractState> {
        fn register_asset(
            ref self: ContractState,
            asset: ContractAddress,
            metric_threshold: u256,
            min_amount_to_limit: u256
        ) {
            self._assert_only_admin();
            
            let mut limiter = self.token_limiters.read(asset);
            LimiterLibImpl::init(ref limiter, metric_threshold, min_amount_to_limit);
            self.token_limiters.write(asset, limiter);
            
            self.emit(Event::AssetRegistered(AssetRegistered {
                asset,
                metric_threshold,
                min_amount_to_limit
            }));
        }

        fn update_asset_params(
            ref self: ContractState,
            asset: ContractAddress,
            metric_threshold: u256,
            min_amount_to_limit: u256
        ) {
            self._assert_only_admin();
            
            let mut limiter = self.token_limiters.read(asset);
            LimiterLibImpl::update_params(ref limiter, metric_threshold, min_amount_to_limit);
            
            // Sync the limiter
            self._sync_limiter(asset, 0xffffffffffffffffffffffffffffffff);
            
            self.token_limiters.write(asset, limiter);
        }

        fn on_token_inflow(ref self: ContractState, token: ContractAddress, amount: u256) {
            self._assert_only_protected();
            self.pausable.assert_not_paused();
            self._on_token_inflow(token, amount);
        }

        fn on_token_outflow(
            ref self: ContractState,
            token: ContractAddress,
            amount: u256,
            recipient: ContractAddress,
            revert_on_rate_limit: bool
        ) {
            self._assert_only_protected();
            self.pausable.assert_not_paused();
            self._on_token_outflow(token, amount, recipient, revert_on_rate_limit);
        }

        fn on_native_asset_inflow(ref self: ContractState, amount: u256) {
            self._assert_only_protected();
            self.pausable.assert_not_paused();
            let native_proxy = self.native_address_proxy.read();
            self._on_token_inflow(native_proxy, amount);
        }

        fn on_native_asset_outflow(
            ref self: ContractState,
            recipient: ContractAddress,
            revert_on_rate_limit: bool
        ) -> bool {
            self._assert_only_protected();
            self.pausable.assert_not_paused();
            
            let native_proxy = self.native_address_proxy.read();
            // In Starknet, we need to handle native token differently
            // This is a placeholder - actual implementation would depend on Starknet's native token handling
            let amount: u256 = 0; // Should get msg.value equivalent
            
            self._on_token_outflow(native_proxy, amount, recipient, revert_on_rate_limit);
            true
        }

        fn claim_locked_funds(ref self: ContractState, asset: ContractAddress, recipient: ContractAddress) {
            self.pausable.assert_not_paused();
            
            let amount = self.locked_funds.read((recipient, asset));
            assert(amount > 0, Errors::NO_LOCKED_FUNDS);
            assert(!self.is_rate_limited.read(), Errors::RATE_LIMITED);
            
            self.locked_funds.write((recipient, asset), 0);
            
            self.emit(Event::LockedFundsClaimed(LockedFundsClaimed { asset, recipient }));
            
            self._safe_transfer_including_native(asset, recipient, amount);
        }

        fn clear_backlog(ref self: ContractState, token: ContractAddress, max_iterations: u256) {
            self._sync_limiter(token, max_iterations);
            
            self.emit(Event::TokenBacklogCleaned(TokenBacklogCleaned {
                token,
                timestamp: get_block_timestamp(),
            }));
        }

        fn override_expired_rate_limit(ref self: ContractState) {
            assert(self.is_rate_limited.read(), Errors::NOT_RATE_LIMITED);
            
            let cooldown_period = self.rate_limit_cooldown_period.read();
            let last_limit_time = self.last_rate_limit_timestamp.read();
            
            assert(
                get_block_timestamp() - last_limit_time >= cooldown_period,
                Errors::COOLDOWN_PERIOD_NOT_REACHED
            );
            
            self.is_rate_limited.write(false);
        }

        fn set_admin(ref self: ContractState, new_admin: ContractAddress) {
            self._assert_only_admin();
            assert(!new_admin.is_zero(), Errors::INVALID_ADMIN_ADDRESS);
            
            self.admin.write(new_admin);
            self.ownable._transfer_ownership(new_admin);
            self.emit(Event::AdminSet(AdminSet { new_admin }));
        }

        fn override_rate_limit(ref self: ContractState) {
            self._assert_only_admin();
            assert(self.is_rate_limited.read(), Errors::NOT_RATE_LIMITED);
            
            self.is_rate_limited.write(false);
            let withdrawal_period = self.withdrawal_period.read();
            let last_limit_time = self.last_rate_limit_timestamp.read();
            self.grace_period_end_timestamp.write(last_limit_time + withdrawal_period);
        }

        fn add_protected_contracts(ref self: ContractState, protected_contracts: Array<ContractAddress>) {
            self._assert_only_admin();
            
            let mut i = 0;
            while i < protected_contracts.len() {
                self.is_protected_contract.write(*protected_contracts.at(i), true);
                i += 1;
            }
        }

        fn remove_protected_contracts(ref self: ContractState, protected_contracts: Array<ContractAddress>) {
            self._assert_only_admin();
            
            let mut i = 0;
            while i < protected_contracts.len() {
                self.is_protected_contract.write(*protected_contracts.at(i), false);
                i += 1;
            }
        }

        fn start_grace_period(ref self: ContractState, grace_period_end_timestamp: u64) {
            self._assert_only_admin();
            assert(grace_period_end_timestamp > get_block_timestamp(), Errors::INVALID_GRACE_PERIOD_END);
            
            self.grace_period_end_timestamp.write(grace_period_end_timestamp);
            self.emit(Event::GracePeriodStarted(GracePeriodStarted { grace_period_end: grace_period_end_timestamp }));
        }

        fn mark_as_not_operational(ref self: ContractState) {
            self._assert_only_admin();
            self.pausable.pause();
        }

        fn migrate_funds_after_exploit(
            ref self: ContractState,
            assets: Array<ContractAddress>,
            recovery_recipient: ContractAddress
        ) {
            self._assert_only_admin();
            assert(self.pausable.is_paused(), Errors::NOT_EXPLOITED);
            
            let mut i = 0;
            while i < assets.len() {
                let asset = *assets.at(i);
                let native_proxy = self.native_address_proxy.read();
                
                let amount = if asset == native_proxy {
                    // For native asset, would need balance check
                    0 // Placeholder - would get contract balance
                } else {
                    let token = IERC20Dispatcher { contract_address: asset };
                    token.balance_of(get_contract_address())
                };
                
                if amount > 0 {
                    self._safe_transfer_including_native(asset, recovery_recipient, amount);
                }
                i += 1;
            }
        }

        // View functions
        fn locked_funds(self: @ContractState, recipient: ContractAddress, asset: ContractAddress) -> u256 {
            self.locked_funds.read((recipient, asset))
        }

        fn is_protected_contract(self: @ContractState, account: ContractAddress) -> bool {
            self.is_protected_contract.read(account)
        }

        fn admin(self: @ContractState) -> ContractAddress {
            self.admin.read()
        }

        fn is_rate_limited(self: @ContractState) -> bool {
            self.is_rate_limited.read()
        }

        fn rate_limit_cooldown_period(self: @ContractState) -> u64 {
            self.rate_limit_cooldown_period.read()
        }

        fn last_rate_limit_timestamp(self: @ContractState) -> u64 {
            self.last_rate_limit_timestamp.read()
        }

        fn grace_period_end_timestamp(self: @ContractState) -> u64 {
            self.grace_period_end_timestamp.read()
        }

        fn is_rate_limit_triggered(self: @ContractState, asset: ContractAddress) -> bool {
            let limiter = self.token_limiters.read(asset);
            LimiterLibImpl::status(@limiter) == LimitStatus::Triggered
        }

        fn is_in_grace_period(self: @ContractState) -> bool {
            get_block_timestamp() <= self.grace_period_end_timestamp.read()
        }

        fn is_operational(self: @ContractState) -> bool {
            !self.pausable.is_paused()
        }

        fn token_liquidity_changes(
            self: @ContractState,
            token: ContractAddress,
            tick_timestamp: u64
        ) -> (u64, SignedU256) {
            let node = self.list_nodes.read((token, tick_timestamp));
            (node.next_timestamp, node.amount)
        }

        fn withdrawal_period(self: @ContractState) -> u64 {
            self.withdrawal_period.read()
        }

        fn tick_length(self: @ContractState) -> u64 {
            self.tick_length.read()
        }

        fn native_address_proxy(self: @ContractState) -> ContractAddress {
            self.native_address_proxy.read()
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _assert_only_protected(self: @ContractState) {
            let caller = get_caller_address();
            assert(self.is_protected_contract.read(caller), Errors::NOT_A_PROTECTED_CONTRACT);
        }

        fn _assert_only_admin(self: @ContractState) {
            let caller = get_caller_address();
            assert(caller == self.admin.read(), Errors::NOT_ADMIN);
        }

        fn _sync_limiter(ref self: ContractState, token: ContractAddress, max_iterations: u256) {
            let mut limiter = self.token_limiters.read(token);
            let withdrawal_period = self.withdrawal_period.read();
            
            let mut current_head = limiter.list_head;
            let mut total_change = SignedU256Trait::zero();
            let mut iter: u256 = 0;

            while current_head != 0 
                && get_block_timestamp() - current_head >= withdrawal_period 
                && iter < max_iterations {
                
                let node = self.list_nodes.read((token, current_head));
                total_change = total_change.add(node.amount);
                let next_timestamp = node.next_timestamp;
                
                self.list_nodes.write((token, current_head), LiqChangeNode {
                    amount: SignedU256Trait::zero(),
                    next_timestamp: 0,
                });

                current_head = next_timestamp;
                iter += 1;
            }

            if current_head == 0 {
                limiter.list_head = 0;
                limiter.list_tail = 0;
            } else {
                limiter.list_head = current_head;
            }

            limiter.liq_total = limiter.liq_total.add(total_change);
            limiter.liq_in_period = limiter.liq_in_period.sub(total_change);
            
            self.token_limiters.write(token, limiter);
        }

        fn _record_change(ref self: ContractState, token: ContractAddress, amount: SignedU256) {
            let mut limiter = self.token_limiters.read(token);
            
            if !limiter.initialized {
                return;
            }

            let withdrawal_period = self.withdrawal_period.read();
            let tick_length = self.tick_length.read();
            let current_tick_timestamp = self._get_tick_timestamp(get_block_timestamp(), tick_length);
            
            limiter.liq_in_period = limiter.liq_in_period.add(amount);

            let list_head = limiter.list_head;
            if list_head == 0 {
                limiter.list_head = current_tick_timestamp;
                limiter.list_tail = current_tick_timestamp;
                self.list_nodes.write((token, current_tick_timestamp), LiqChangeNode {
                    amount: amount,
                    next_timestamp: 0,
                });
            } else {
                if get_block_timestamp() - list_head >= withdrawal_period {
                    self._sync_limiter(token, 0xffffffffffffffffffffffffffffffff);
                    // Re-read the limiter after sync
                    limiter = self.token_limiters.read(token);
                }

                let list_tail = limiter.list_tail;
                if list_tail == current_tick_timestamp {
                    let mut current_node = self.list_nodes.read((token, current_tick_timestamp));
                    current_node.amount = current_node.amount.add(amount);
                    self.list_nodes.write((token, current_tick_timestamp), current_node);
                } else {
                    let mut tail_node = self.list_nodes.read((token, list_tail));
                    tail_node.next_timestamp = current_tick_timestamp;
                    self.list_nodes.write((token, list_tail), tail_node);
                    
                    self.list_nodes.write((token, current_tick_timestamp), LiqChangeNode {
                        amount: amount,
                        next_timestamp: 0,
                    });
                    limiter.list_tail = current_tick_timestamp;
                }
            }
            
            self.token_limiters.write(token, limiter);
        }

        fn _get_tick_timestamp(self: @ContractState, timestamp: u64, tick_length: u64) -> u64 {
            timestamp - (timestamp % tick_length)
        }

        fn _on_token_inflow(ref self: ContractState, token: ContractAddress, amount: u256) {
            let signed_amount = SignedU256Trait::from_u256(amount);
            self._record_change(token, signed_amount);
            self.emit(Event::AssetInflow(AssetInflow { token, amount }));
        }

        fn _on_token_outflow(
            ref self: ContractState,
            token: ContractAddress,
            amount: u256,
            recipient: ContractAddress,
            revert_on_rate_limit: bool
        ) {
            let limiter = self.token_limiters.read(token);
            
            // If token is not registered, just transfer
            if !LimiterLibImpl::initialized(@limiter) {
                self._safe_transfer_including_native(token, recipient, amount);
                return;
            }

            let signed_amount = SignedU256Trait::new(amount, true); // negative for outflow
            self._record_change(token, signed_amount);

            // Check if currently rate limited
            if self.is_rate_limited.read() {
                if revert_on_rate_limit {
                    panic_with_felt252(Errors::RATE_LIMITED);
                }
                let current_locked = self.locked_funds.read((recipient, token));
                self.locked_funds.write((recipient, token), current_locked + amount);
                return;
            }

            // Re-read limiter after record_change
            let limiter = self.token_limiters.read(token);
            
            // Check if rate limit is triggered and not in grace period
            if LimiterLibImpl::status(@limiter) == LimitStatus::Triggered && !self._is_in_grace_period() {
                if revert_on_rate_limit {
                    panic_with_felt252(Errors::RATE_LIMITED);
                }

                // Set rate limited state
                self.is_rate_limited.write(true);
                self.last_rate_limit_timestamp.write(get_block_timestamp());
                
                // Lock the funds
                let current_locked = self.locked_funds.read((recipient, token));
                self.locked_funds.write((recipient, token), current_locked + amount);
                
                self.emit(Event::AssetRateLimitBreached(AssetRateLimitBreached {
                    asset: token,
                    timestamp: get_block_timestamp(),
                }));
                
                return;
            }

            // Normal transfer
            self._safe_transfer_including_native(token, recipient, amount);
            
            self.emit(Event::AssetWithdraw(AssetWithdraw { asset: token, recipient, amount }));
        }

        fn _safe_transfer_including_native(
            ref self: ContractState,
            token: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {
            if amount == 0 {
                return;
            }

            let native_proxy = self.native_address_proxy.read();
            if token == native_proxy {
                // Native transfer - in Cairo/Starknet, this would be handled differently
                // For now, we'll use a placeholder implementation
                self._transfer_native(recipient, amount);
            } else {
                let erc20 = IERC20Dispatcher { contract_address: token };
                let success = erc20.transfer(recipient, amount);
                assert(success, Errors::NATIVE_TRANSFER_FAILED);
            }
        }

        fn _transfer_native(ref self: ContractState, recipient: ContractAddress, amount: u256) {
            // Placeholder for native token transfer
            // In Starknet, native token transfers are handled differently
            // This would typically involve calling the ETH contract directly
            // For production, implement proper ETH transfer logic here
        }

        fn _is_in_grace_period(self: @ContractState) -> bool {
            get_block_timestamp() <= self.grace_period_end_timestamp.read()
        }
    }
}
