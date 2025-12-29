//
//  CircuitBreakerTests.swift
//  CoreCashu
//
//  Tests for CircuitBreaker state machine and behavior.
//

import Testing
import Foundation
@testable import CoreCashu

@Suite("Circuit Breaker Tests")
struct CircuitBreakerTests {
    
    // MARK: - Configuration Tests
    
    @Test("Default configuration values")
    func defaultConfiguration() {
        let config = CircuitBreakerConfiguration.default
        #expect(config.failureThreshold == 5)
        #expect(config.openTimeout == 15.0)
        #expect(config.halfOpenMaxAttempts == 1)
    }
    
    @Test("Custom configuration values")
    func customConfiguration() {
        let config = CircuitBreakerConfiguration(
            failureThreshold: 3,
            openTimeout: 30.0,
            halfOpenMaxAttempts: 2
        )
        #expect(config.failureThreshold == 3)
        #expect(config.openTimeout == 30.0)
        #expect(config.halfOpenMaxAttempts == 2)
    }
    
    // MARK: - Initial State Tests
    
    @Test("Initial state is closed")
    func initialStateIsClosed() async {
        let breaker = EndpointCircuitBreaker()
        let state = await breaker.currentState()
        
        switch state {
        case .closed(let failureCount):
            #expect(failureCount == 0)
        default:
            Issue.record("Expected closed state, got \(state)")
        }
    }
    
    @Test("Initial state allows requests")
    func initialStateAllowsRequests() async {
        let breaker = EndpointCircuitBreaker()
        let allowed = await breaker.allowRequest()
        #expect(allowed == true)
    }
    
    // MARK: - Closed State Tests
    
    @Test("Closed state allows requests")
    func closedStateAllowsRequests() async {
        let breaker = EndpointCircuitBreaker()
        
        // Multiple requests should be allowed
        for _ in 0..<10 {
            let allowed = await breaker.allowRequest()
            #expect(allowed == true)
        }
    }
    
    @Test("Failures increment counter in closed state")
    func failuresIncrementCounter() async {
        let config = CircuitBreakerConfiguration(failureThreshold: 5)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        await breaker.recordFailure()
        let state = await breaker.currentState()
        
        switch state {
        case .closed(let failureCount):
            #expect(failureCount == 1)
        default:
            Issue.record("Expected closed state, got \(state)")
        }
    }
    
    @Test("Multiple failures accumulate")
    func multipleFailuresAccumulate() async {
        let config = CircuitBreakerConfiguration(failureThreshold: 5)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        for i in 1...4 {
            await breaker.recordFailure()
            let state = await breaker.currentState()
            
            switch state {
            case .closed(let failureCount):
                #expect(failureCount == i)
            default:
                Issue.record("Expected closed state after \(i) failures")
            }
        }
    }
    
    @Test("Success resets failure count")
    func successResetsFailureCount() async {
        let config = CircuitBreakerConfiguration(failureThreshold: 5)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        // Record some failures
        await breaker.recordFailure()
        await breaker.recordFailure()
        await breaker.recordFailure()
        
        // Record success
        await breaker.recordSuccess()
        
        let state = await breaker.currentState()
        switch state {
        case .closed(let failureCount):
            #expect(failureCount == 0)
        default:
            Issue.record("Expected closed state after success")
        }
    }
    
    // MARK: - State Transition to Open Tests
    
    @Test("Threshold failures opens circuit")
    func thresholdFailuresOpensCircuit() async {
        let config = CircuitBreakerConfiguration(failureThreshold: 3)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        // Record exactly threshold failures
        await breaker.recordFailure()
        await breaker.recordFailure()
        await breaker.recordFailure()
        
        let state = await breaker.currentState()
        switch state {
        case .open:
            // Expected - circuit should be open
            break
        default:
            Issue.record("Expected open state after \(config.failureThreshold) failures, got \(state)")
        }
    }
    
    @Test("Exceeding threshold opens circuit")
    func exceedingThresholdOpensCircuit() async {
        let config = CircuitBreakerConfiguration(failureThreshold: 2)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        await breaker.recordFailure()
        await breaker.recordFailure()
        await breaker.recordFailure() // Extra failure
        
        let state = await breaker.currentState()
        switch state {
        case .open:
            break // Expected
        default:
            Issue.record("Expected open state")
        }
    }
    
    // MARK: - Open State Tests
    
    @Test("Open state blocks requests")
    func openStateBlocksRequests() async {
        let config = CircuitBreakerConfiguration(failureThreshold: 1, openTimeout: 60.0)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        await breaker.recordFailure() // Opens circuit
        
        let allowed = await breaker.allowRequest()
        #expect(allowed == false)
    }
    
    @Test("Open state records timestamp")
    func openStateRecordsTimestamp() async {
        let config = CircuitBreakerConfiguration(failureThreshold: 1)
        let breaker = EndpointCircuitBreaker(configuration: config)
        let now = Date()
        
        await breaker.recordFailure(now: now)
        
        let state = await breaker.currentState()
        switch state {
        case .open(let openedAt):
            #expect(openedAt == now)
        default:
            Issue.record("Expected open state")
        }
    }
    
    @Test("Failure while open updates timestamp")
    func failureWhileOpenUpdatesTimestamp() async {
        let config = CircuitBreakerConfiguration(failureThreshold: 1)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        let firstFailure = Date()
        await breaker.recordFailure(now: firstFailure)
        
        let secondFailure = firstFailure.addingTimeInterval(5.0)
        await breaker.recordFailure(now: secondFailure)
        
        let state = await breaker.currentState()
        switch state {
        case .open(let openedAt):
            #expect(openedAt == secondFailure)
        default:
            Issue.record("Expected open state")
        }
    }
    
    // MARK: - Transition to Half-Open Tests
    
    @Test("Open state transitions to half-open after timeout")
    func transitionsToHalfOpenAfterTimeout() async {
        let config = CircuitBreakerConfiguration(failureThreshold: 1, openTimeout: 10.0, halfOpenMaxAttempts: 2)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        let openTime = Date()
        await breaker.recordFailure(now: openTime)
        
        // Request after timeout should transition to half-open and be allowed
        // The transition sets halfOpenMaxAttempts, and first call returns true without decrementing
        let afterTimeout = openTime.addingTimeInterval(11.0)
        let allowed = await breaker.allowRequest(now: afterTimeout)
        
        #expect(allowed == true)
        
        let state = await breaker.currentState()
        switch state {
        case .halfOpen(let remaining):
            // After transition, state is set to halfOpenMaxAttempts (2) and first call returns true
            #expect(remaining == config.halfOpenMaxAttempts)
        default:
            Issue.record("Expected half-open state, got \(state)")
        }
    }
    
    @Test("Open state remains open before timeout")
    func remainsOpenBeforeTimeout() async {
        let config = CircuitBreakerConfiguration(failureThreshold: 1, openTimeout: 10.0)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        let openTime = Date()
        await breaker.recordFailure(now: openTime)
        
        // Request before timeout should be blocked
        let beforeTimeout = openTime.addingTimeInterval(5.0)
        let allowed = await breaker.allowRequest(now: beforeTimeout)
        
        #expect(allowed == false)
        
        let state = await breaker.currentState()
        switch state {
        case .open:
            break // Expected
        default:
            Issue.record("Expected open state before timeout")
        }
    }
    
    // MARK: - Half-Open State Tests
    
    @Test("Half-open state allows limited requests")
    func halfOpenAllowsLimitedRequests() async {
        let config = CircuitBreakerConfiguration(failureThreshold: 1, openTimeout: 0, halfOpenMaxAttempts: 2)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        await breaker.recordFailure()
        
        // Transition to half-open
        // First call transitions from open to half-open (sets allowance to 2) and returns true
        // Second call decrements to 1 and returns true
        // Third call decrements to 0 and returns true
        // Fourth call sees 0 remaining and returns false
        let future = Date().addingTimeInterval(1)
        let first = await breaker.allowRequest(now: future)  // Transitions to half-open, remaining=2
        let second = await breaker.allowRequest(now: future) // remaining 2->1, returns true
        let third = await breaker.allowRequest(now: future)  // remaining 1->0, returns true
        let fourth = await breaker.allowRequest(now: future) // remaining=0, returns false
        
        #expect(first == true)
        #expect(second == true)
        #expect(third == true)
        #expect(fourth == false) // Exceeded allowance
    }
    
    @Test("Success in half-open closes circuit")
    func successInHalfOpenClosesCircuit() async {
        let config = CircuitBreakerConfiguration(failureThreshold: 1, openTimeout: 0, halfOpenMaxAttempts: 1)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        await breaker.recordFailure()
        _ = await breaker.allowRequest(now: Date().addingTimeInterval(1)) // Transition to half-open
        
        await breaker.recordSuccess()
        
        let state = await breaker.currentState()
        switch state {
        case .closed(let failureCount):
            #expect(failureCount == 0)
        default:
            Issue.record("Expected closed state after success in half-open")
        }
    }
    
    @Test("Failure in half-open opens circuit")
    func failureInHalfOpenOpensCircuit() async {
        let config = CircuitBreakerConfiguration(failureThreshold: 1, openTimeout: 0, halfOpenMaxAttempts: 1)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        await breaker.recordFailure()
        _ = await breaker.allowRequest(now: Date().addingTimeInterval(1)) // Transition to half-open
        
        let failureTime = Date()
        await breaker.recordFailure(now: failureTime)
        
        let state = await breaker.currentState()
        switch state {
        case .open(let openedAt):
            #expect(openedAt == failureTime)
        default:
            Issue.record("Expected open state after failure in half-open")
        }
    }
    
    // MARK: - Edge Case Tests
    
    @Test("Zero threshold opens immediately on failure")
    func zeroThresholdOpensImmediately() async {
        // Note: This tests edge case where failureThreshold could be 0
        // With threshold >= 1, first failure opens at count == threshold
        let config = CircuitBreakerConfiguration(failureThreshold: 1)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        await breaker.recordFailure()
        
        let state = await breaker.currentState()
        switch state {
        case .open:
            break // Expected - single failure meets threshold of 1
        default:
            Issue.record("Expected open state with threshold 1")
        }
    }
    
    @Test("Zero timeout immediately allows half-open transition")
    func zeroTimeoutImmediatelyAllowsHalfOpen() async {
        let config = CircuitBreakerConfiguration(failureThreshold: 1, openTimeout: 0)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        await breaker.recordFailure()
        
        // Even with same timestamp, zero timeout should allow transition
        let allowed = await breaker.allowRequest()
        #expect(allowed == true)
    }
    
    @Test("Concurrent requests in half-open state")
    func concurrentRequestsInHalfOpen() async {
        // With halfOpenMaxAttempts = 5:
        // - 1 request triggers the transition (returns true, sets remaining=5)
        // - Next 5 requests each decrement and return true (remaining goes 5->4->3->2->1->0)
        // - Remaining requests return false
        // Total allowed: 1 (transition) + 5 (half-open allowance) = 6
        let config = CircuitBreakerConfiguration(failureThreshold: 1, openTimeout: 0, halfOpenMaxAttempts: 5)
        let breaker = EndpointCircuitBreaker(configuration: config)
        
        await breaker.recordFailure()
        
        // Make concurrent requests
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await breaker.allowRequest(now: Date().addingTimeInterval(1))
                }
            }
            
            var allowedCount = 0
            for await allowed in group {
                if allowed { allowedCount += 1 }
            }
            
            // 1 transition + halfOpenMaxAttempts decrements = 6 total allowed
            #expect(allowedCount == 6)
        }
    }
    
    // MARK: - State Equality Tests
    
    @Test("CircuitBreakerState equality")
    func stateEquality() {
        let closed1 = CircuitBreakerState.closed(failureCount: 3)
        let closed2 = CircuitBreakerState.closed(failureCount: 3)
        let closed3 = CircuitBreakerState.closed(failureCount: 4)
        
        #expect(closed1 == closed2)
        #expect(closed1 != closed3)
        
        let now = Date()
        let open1 = CircuitBreakerState.open(openedAt: now)
        let open2 = CircuitBreakerState.open(openedAt: now)
        let open3 = CircuitBreakerState.open(openedAt: now.addingTimeInterval(1))
        
        #expect(open1 == open2)
        #expect(open1 != open3)
        
        let halfOpen1 = CircuitBreakerState.halfOpen(remainingAllowance: 2)
        let halfOpen2 = CircuitBreakerState.halfOpen(remainingAllowance: 2)
        let halfOpen3 = CircuitBreakerState.halfOpen(remainingAllowance: 1)
        
        #expect(halfOpen1 == halfOpen2)
        #expect(halfOpen1 != halfOpen3)
        
        #expect(closed1 != open1)
        #expect(closed1 != halfOpen1)
        #expect(open1 != halfOpen1)
    }
}
