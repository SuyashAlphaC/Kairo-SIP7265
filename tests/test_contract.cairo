    use starknet::{ContractAddress, contract_address_const, get_block_timestamp};
    use starknet::testing::{set_caller_address, set_contract_address, set_block_timestamp};
    
    use snforge_std::{
        declare, ContractClassTrait, DeclareResultTrait,
        start_cheat_caller_address, stop_cheat_caller_address,
        start_cheat_block_timestamp, stop_cheat_block_timestamp,
    };
    
    use circuit_breaker::core::circuit_breaker::CircuitBreaker;
    use circuit_breaker::interfaces::circuit_breaker_interface::{
        ICircuitBreakerDispatcher, ICircuitBreakerDispatcherTrait
    };
    use circuit_breaker::mocks::mock_token::{
        IMockTokenDispatcher, IMockTokenDispatcherTrait
    };
    use circuit_breaker::mocks::mock_defi_protocol::{
        IMockDeFiProtocolDispatcher, IMockDeFiProtocolDispatcherTrait
    };

    use openzeppelin_security::interface::{IPausableDispatcher, IPausableDispatcherTrait};

    fn deploy_circuit_breaker() -> ICircuitBreakerDispatcher {
        let admin = contract_address_const::<'admin'>();
        let rate_limit_cooldown_period: u64 = 259200; // 3 days in seconds
        let withdrawal_period: u64 = 14400; // 4 hours in seconds
        let tick_length: u64 = 300; // 5 minutes in seconds
        
        let circuit_breaker_class = declare("CircuitBreaker").unwrap().contract_class();
        let (contract_address, _) = circuit_breaker_class.deploy(
            @array![
                admin.into(),
                rate_limit_cooldown_period.into(),
                withdrawal_period.into(),
                tick_length.into()
            ]
        ).unwrap();
        
        ICircuitBreakerDispatcher { contract_address }
    }
    
    fn deploy_mock_token(name: felt252, symbol: felt252) -> IMockTokenDispatcher {
        let contract = declare("MockToken").unwrap().contract_class();
        let (contract_address, _) = contract.deploy(
            @array![name, symbol]
        ).unwrap();
        
        IMockTokenDispatcher { contract_address }
    }

    fn deploy_mock_defi(circuit_breaker: ContractAddress) -> IMockDeFiProtocolDispatcher {
        let contract = declare("MockDeFiProtocol").unwrap().contract_class();
        let (contract_address, _) = contract.deploy(
            @array![circuit_breaker.into()]
        ).unwrap();
        
        IMockDeFiProtocolDispatcher { contract_address }
    }

    #[test]
    fn test_initialization() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        
        assert_eq!(circuit_breaker.admin(), admin);
        assert_eq!(circuit_breaker.rate_limit_cooldown_period(), 259200);
        assert_eq!(circuit_breaker.withdrawal_period(), 14400);
        assert_eq!(circuit_breaker.tick_length(), 300);
        assert_eq!(circuit_breaker.is_operational(), true);
        assert_eq!(circuit_breaker.is_rate_limited(), false);
    }

    #[test]
    fn test_register_asset() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let token = deploy_mock_token('USDC','USDC');
        
        // Register asset as admin
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.register_asset(
            token.contract_address,
            7000, // 70% retention
            1000000000000000000000 // 1000 tokens minimum
        );
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Verify registration
        assert_eq!(circuit_breaker.is_rate_limit_triggered(token.contract_address), false);
    }

    #[test]
    #[should_panic(expected: ('Not admin',))]
    fn test_register_asset_unauthorized() {
        let circuit_breaker = deploy_circuit_breaker();
        let unauthorized = contract_address_const::<'unauthorized'>();
        let token = deploy_mock_token('USDC','USDC');
        
        // Try to register asset as non-admin (should panic)
        start_cheat_caller_address(circuit_breaker.contract_address, unauthorized);
        circuit_breaker.register_asset(
            token.contract_address,
            7000,
            1000000000000000000000
        );
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    #[test]
    fn test_add_protected_contracts() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let defi = deploy_mock_defi(circuit_breaker.contract_address);
        
        // Add protected contract
        let mut protected_contracts = array![defi.contract_address];
        
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Verify protection
        assert_eq!(circuit_breaker.is_protected_contract(defi.contract_address), true);
    }

    #[test]
    fn test_deposit_and_withdrawal_no_breach() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let alice = contract_address_const::<'alice'>();
        let token = deploy_mock_token('USDC','USDC');
        let defi = deploy_mock_defi(circuit_breaker.contract_address);
        
        // Setup: Register asset and add protected contract
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.register_asset(
            token.contract_address,
            7000, // 70% retention
            1000000000000000000000 // 1000 tokens minimum
        );
        
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Mint tokens to Alice
        let mint_amount: u256 = 10000000000000000000000; // 10000 tokens
        token.mint(alice, mint_amount);
        
        // Approve DeFi protocol
        start_cheat_caller_address(token.contract_address, alice);
        token.approve(defi.contract_address, mint_amount);
        stop_cheat_caller_address(token.contract_address);
        
        // Deposit tokens
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token.contract_address, 100000000000000000000); // 100 tokens
        stop_cheat_caller_address(defi.contract_address);
        
        // Fast forward time
        start_cheat_block_timestamp(circuit_breaker.contract_address, 3600); // 1 hour later
        
        // Withdraw tokens (within safe limits)
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token.contract_address, 60000000000000000000); // 60 tokens
        stop_cheat_caller_address(defi.contract_address);
        
        stop_cheat_block_timestamp(circuit_breaker.contract_address);
        
        // Verify no rate limit triggered
        assert_eq!(circuit_breaker.is_rate_limited(), false);
        assert_eq!(circuit_breaker.is_rate_limit_triggered(token.contract_address), false);
    }

    #[test]
    fn test_rate_limit_breach() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let alice = contract_address_const::<'alice'>();
        let token = deploy_mock_token('USDC','USDC');
        let defi = deploy_mock_defi(circuit_breaker.contract_address);
        
        // Setup: Register asset and add protected contract
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.register_asset(
            token.contract_address,
            7000, // 70% retention
            1000000000000000000000 // 1000 tokens minimum
        );
        
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Mint and deposit 1 million tokens
        let large_amount: u256 = 1000000000000000000000000; // 1 million tokens
        token.mint(alice, large_amount);
        
        start_cheat_caller_address(token.contract_address, alice);
        token.approve(defi.contract_address, large_amount);
        stop_cheat_caller_address(token.contract_address);
        
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token.contract_address, large_amount);
        stop_cheat_caller_address(defi.contract_address);
        
        // Fast forward time to allow withdrawal period
        start_cheat_block_timestamp(circuit_breaker.contract_address, 18000); // 5 hours later
        
        // Attempt to withdraw more than 30% (should trigger rate limit)
        let breach_amount: u256 = 300001000000000000000000; // 300,001 tokens
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token.contract_address, breach_amount);
        stop_cheat_caller_address(defi.contract_address);
        
        stop_cheat_block_timestamp(circuit_breaker.contract_address);
        
        // Verify rate limit triggered
        assert_eq!(circuit_breaker.is_rate_limited(), true);
        assert_eq!(circuit_breaker.is_rate_limit_triggered(token.contract_address), true);
        
        // Verify funds are locked
        assert_eq!(circuit_breaker.locked_funds(alice, token.contract_address), breach_amount);
    }

    #[test]
    fn test_claim_locked_funds_after_override() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let alice = contract_address_const::<'alice'>();
        let token = deploy_mock_token('USDC','USDC');
        let defi = deploy_mock_defi(circuit_breaker.contract_address);
        
        // Setup and trigger rate limit (similar to previous test)
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.register_asset(
            token.contract_address,
            7000,
            1000000000000000000000
        );
        
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Deposit and trigger rate limit
        let large_amount: u256 = 1000000000000000000000000;
        token.mint(alice, large_amount);
        
        start_cheat_caller_address(token.contract_address, alice);
        token.approve(defi.contract_address, large_amount);
        stop_cheat_caller_address(token.contract_address);
        
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token.contract_address, large_amount);
        stop_cheat_caller_address(defi.contract_address);
        
        start_cheat_block_timestamp(circuit_breaker.contract_address, 18000);
        
        let breach_amount: u256 = 300001000000000000000000;
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token.contract_address, breach_amount);
        stop_cheat_caller_address(defi.contract_address);
        
        // Admin overrides rate limit
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.override_rate_limit();
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Alice claims locked funds
        start_cheat_caller_address(circuit_breaker.contract_address, alice);
        circuit_breaker.claim_locked_funds(token.contract_address, alice);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        stop_cheat_block_timestamp(circuit_breaker.contract_address);
        
        // Verify funds claimed
        assert_eq!(circuit_breaker.locked_funds(alice, token.contract_address), 0);
        assert_eq!(circuit_breaker.is_rate_limited(), false);
    }

    #[test]
    fn test_grace_period() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        
        // Set grace period
        let grace_period_end: u64 = 86400; // 1 day from now
        
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        start_cheat_block_timestamp(circuit_breaker.contract_address, 0);
        circuit_breaker.start_grace_period(grace_period_end);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        stop_cheat_block_timestamp(circuit_breaker.contract_address);
        
        // Verify grace period
        assert_eq!(circuit_breaker.grace_period_end_timestamp(), grace_period_end);
        assert_eq!(circuit_breaker.is_in_grace_period(), true);
    }

    #[test]
    fn test_emergency_pause() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let token = deploy_mock_token('USDC','USDC');
        let defi = deploy_mock_defi(circuit_breaker.contract_address);
        
        // Setup
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.register_asset(
            token.contract_address,
            7000,
            1000000000000000000000
        );
        
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        
        // Mark as not operational (pause)
        circuit_breaker.mark_as_not_operational();
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Verify paused
        assert_eq!(circuit_breaker.is_operational(), false);
        
        // Check pausable interface
        let pausable = IPausableDispatcher { contract_address: circuit_breaker.contract_address };
        assert_eq!(pausable.is_paused(), true);
    }

    #[test]
    fn test_migrate_funds_after_exploit() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let recovery = contract_address_const::<'recovery'>();
        let alice = contract_address_const::<'alice'>();
        let token = deploy_mock_token('USDC','USDC');
        let defi = deploy_mock_defi(circuit_breaker.contract_address);
        
        // Setup and deposit funds
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.register_asset(
            token.contract_address,
            7000,
            1000000000000000000000
        );
        
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Deposit funds that will be stuck in circuit breaker
        let amount: u256 = 1000000000000000000000;
        token.mint(alice, amount);
        
        start_cheat_caller_address(token.contract_address, alice);
        token.approve(defi.contract_address, amount);
        stop_cheat_caller_address(token.contract_address);
        
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token.contract_address, amount);
        stop_cheat_caller_address(defi.contract_address);
        
        // Trigger rate limit to get funds stuck in circuit breaker
        start_cheat_block_timestamp(circuit_breaker.contract_address, 18000);
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token.contract_address, 400000000000000000000);
        stop_cheat_caller_address(defi.contract_address);
        stop_cheat_block_timestamp(circuit_breaker.contract_address);
        
        // Mark as exploited and migrate funds
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.mark_as_not_operational();
        
        let mut assets = array![token.contract_address];
        circuit_breaker.migrate_funds_after_exploit(assets, recovery);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Verify migration successful
        assert_eq!(circuit_breaker.is_operational(), false);
    }
