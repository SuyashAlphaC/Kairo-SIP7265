use starknet::get_block_timestamp;
use crate::types::structs::{Limiter, LiqChangeNode, SignedU256, SignedU256Trait, LimitStatus};

const BPS_DENOMINATOR: u256 = 10000_u256;

pub mod Errors {
    pub const INVALID_MINIMUM_LIQUIDITY_THRESHOLD: felt252 = 'Invalid min liquidity threshold';
    pub const LIMITER_ALREADY_INITIALIZED: felt252 = 'Limiter already initialized';
    pub const LIMITER_NOT_INITIALIZED: felt252 = 'Limiter not initialized';
}
pub trait MapTrait<T> {
    fn read(ref self: T, key: u64) -> LiqChangeNode;
    fn write(ref self: T, key: u64, value: LiqChangeNode);
}

#[generate_trait]
pub impl LimiterLibImpl of LimiterLibTrait {
    fn init(ref limiter: Limiter, min_liq_retained_bps: u256, limit_begin_threshold: u256) {
        assert(
            min_liq_retained_bps > 0 && min_liq_retained_bps <= BPS_DENOMINATOR, 
            Errors::INVALID_MINIMUM_LIQUIDITY_THRESHOLD
        );
        assert(!limiter.initialized, Errors::LIMITER_ALREADY_INITIALIZED);
        
        limiter.min_liq_retained_bps = min_liq_retained_bps;
        limiter.limit_begin_threshold = limit_begin_threshold;
        limiter.liq_total = SignedU256Trait::zero();
        limiter.liq_in_period = SignedU256Trait::zero();
        limiter.list_head = 0;
        limiter.list_tail = 0;
        limiter.initialized = true;
    }

    fn update_params(ref limiter: Limiter, min_liq_retained_bps: u256, limit_begin_threshold: u256) {
        assert(
            min_liq_retained_bps > 0 && min_liq_retained_bps <= BPS_DENOMINATOR, 
            Errors::INVALID_MINIMUM_LIQUIDITY_THRESHOLD
        );
        assert(limiter.initialized, Errors::LIMITER_NOT_INITIALIZED);
        
        limiter.min_liq_retained_bps = min_liq_retained_bps;
        limiter.limit_begin_threshold = limit_begin_threshold;
    }

    fn record_change<T, +MapTrait<T>, +Drop<T>>(
        ref limiter: Limiter, 
        amount: SignedU256, 
        withdrawal_period: u64, 
        tick_length: u64,
        ref nodes_map: T
    ) {
        if !limiter.initialized {
            return;
        }

        let current_tick_timestamp = get_tick_timestamp(get_block_timestamp(), tick_length);
        limiter.liq_in_period = limiter.liq_in_period.add(amount);

        let list_head = limiter.list_head;
        if list_head == 0 {
            // If there is no head, set the head to the new change
            limiter.list_head = current_tick_timestamp;
            limiter.list_tail = current_tick_timestamp;
            nodes_map.write(current_tick_timestamp, LiqChangeNode {
                amount: amount,
                next_timestamp: 0,
            });
        } else {
            // If there is a head, check if we need to sync old changes
            if get_block_timestamp() - list_head >= withdrawal_period {
                Self::sync(ref limiter, withdrawal_period, 0xffffffffffffffffffffffffffffffff, ref nodes_map);
            }

            // Check if tail is the same as current tick timestamp (multiple txs in same tick)
            let list_tail = limiter.list_tail;
            if list_tail == current_tick_timestamp {
                // Add amount to existing node
                let mut current_node = nodes_map.read(current_tick_timestamp);
                current_node.amount = current_node.amount.add(amount);
                nodes_map.write(current_tick_timestamp, current_node);
            } else {
                // Add new node to tail
                let mut tail_node = nodes_map.read(list_tail);
                tail_node.next_timestamp = current_tick_timestamp;
                nodes_map.write(list_tail, tail_node);
                
                nodes_map.write(current_tick_timestamp, LiqChangeNode {
                    amount: amount,
                    next_timestamp: 0,
                });
                limiter.list_tail = current_tick_timestamp;
            }
        }
    }

    fn sync<T, +MapTrait<T>, +Drop<T>>(
        ref limiter: Limiter, 
        withdrawal_period: u64, 
        total_iters: u256,
        ref nodes_map: T
    ) {
        let mut current_head = limiter.list_head;
        let mut total_change = SignedU256Trait::zero();
        let mut iter: u256 = 0;

        while current_head != 0 
            && get_block_timestamp() - current_head >= withdrawal_period 
            && iter < total_iters {
            
            let node = nodes_map.read(current_head);
            total_change = total_change.add(node.amount);
            let next_timestamp = node.next_timestamp;
            
            // Clear data
            nodes_map.write(current_head, LiqChangeNode {
                amount: SignedU256Trait::zero(),
                next_timestamp: 0,
            });

            current_head = next_timestamp;
            iter += 1;
        }

        if current_head == 0 {
            // If the list is empty, set tail and head to current timestamp
            // Note: Solidity uses block.timestamp here, but we use 0 to indicate empty list
            limiter.list_head = 0;
            limiter.list_tail = 0;
        } else {
            limiter.list_head = current_head;
        }

        limiter.liq_total = limiter.liq_total.add(total_change);
        limiter.liq_in_period = limiter.liq_in_period.sub(total_change);
    }

    fn status(limiter: @Limiter) -> LimitStatus {
        if !*limiter.initialized {
            return LimitStatus::Uninitialized;
        }

        let current_liq = *limiter.liq_total;

        // Only enforce rate limit if there is significant liquidity
        // Check if current liquidity is negative or below threshold
        if current_liq.is_negative {
            return LimitStatus::Inactive;
        }
        
        // Compare threshold against the unsigned value of current liquidity
        if *limiter.limit_begin_threshold > current_liq.value {
            return LimitStatus::Inactive;
        }
        // If we assume the baseline is the peak liquidity during the period:
        // - If liq_in_period is positive, the baseline is current_liq + liq_in_period  
        // - If liq_in_period is negative, the baseline is current_liq - liq_in_period
        let baseline_liq = if (*limiter.liq_in_period).is_negative {
            // If net negative, the peak was higher than current
            current_liq.sub(*limiter.liq_in_period)
        } else {
            // If net positive, the peak is current + positive flows
            current_liq.add(*limiter.liq_in_period)
        };
        
        let min_liq = baseline_liq.mul_bps(*limiter.min_liq_retained_bps);
        
        // Check if current liquidity is below the minimum required
        if current_liq.is_less_than(min_liq) {
            LimitStatus::Triggered
        } else {
            LimitStatus::Ok
        }
    }

    fn initialized(limiter: @Limiter) -> bool {
        *limiter.initialized
    }
}

pub fn get_tick_timestamp(timestamp: u64, tick_length: u64) -> u64 {
    timestamp - (timestamp % tick_length)
}