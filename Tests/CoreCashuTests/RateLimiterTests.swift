//
//  RateLimiterTests.swift
//  CoreCashu
//
//  Tests for RateLimiter and rate limiting functionality.
//

import Testing
import Foundation
@testable import CoreCashu

@Suite("Rate Limiter Tests")
struct RateLimiterTests {
    
    // MARK: - Configuration Tests
    
    @Test("Default configuration values")
    func defaultConfiguration() {
        let config = RateLimitConfiguration.default
        #expect(config.maxRequests == RateLimitConstants.defaultMaxRequests)
        #expect(config.timeWindow == RateLimitConstants.defaultTimeWindow)
        #expect(config.burstCapacity == RateLimitConstants.defaultBurstCapacity)
    }
    
    @Test("Strict configuration values")
    func strictConfiguration() {
        let config = RateLimitConfiguration.strict
        #expect(config.maxRequests == RateLimitConstants.strictMaxRequests)
        #expect(config.timeWindow == RateLimitConstants.defaultTimeWindow)
        #expect(config.burstCapacity == RateLimitConstants.strictBurstCapacity)
    }
    
    @Test("Relaxed configuration values")
    func relaxedConfiguration() {
        let config = RateLimitConfiguration.relaxed
        #expect(config.maxRequests == RateLimitConstants.relaxedMaxRequests)
        #expect(config.timeWindow == RateLimitConstants.defaultTimeWindow)
        #expect(config.burstCapacity == RateLimitConstants.relaxedBurstCapacity)
    }
    
    @Test("Custom configuration values")
    func customConfiguration() {
        let config = RateLimitConfiguration(
            maxRequests: 100,
            timeWindow: 30.0,
            burstCapacity: 15
        )
        #expect(config.maxRequests == 100)
        #expect(config.timeWindow == 30.0)
        #expect(config.burstCapacity == 15)
    }
    
    // MARK: - Basic Rate Limiter Tests
    
    @Test("Initial state allows requests")
    func initialStateAllowsRequests() async {
        let limiter = RateLimiter(configuration: .default)
        let allowed = await limiter.shouldAllowRequest()
        #expect(allowed == true)
    }
    
    @Test("Record request decrements tokens")
    func recordRequestDecrementsTokens() async {
        let config = RateLimitConfiguration(maxRequests: 60, timeWindow: 60.0, burstCapacity: 5)
        let limiter = RateLimiter(configuration: config)
        
        let statusBefore = await limiter.getStatus()
        #expect(statusBefore.tokensAvailable == 5)
        
        await limiter.recordRequest()
        
        let statusAfter = await limiter.getStatus()
        #expect(statusAfter.tokensAvailable == 4)
    }
    
    @Test("Multiple requests track correctly")
    func multipleRequestsTrackCorrectly() async {
        let config = RateLimitConfiguration(maxRequests: 10, timeWindow: 60.0, burstCapacity: 5)
        let limiter = RateLimiter(configuration: config)
        
        for _ in 0..<3 {
            await limiter.recordRequest()
        }
        
        let status = await limiter.getStatus()
        #expect(status.requestsUsed == 3)
        #expect(status.tokensAvailable == 2)
    }
    
    // MARK: - Rate Limit Enforcement Tests
    
    @Test("Burst capacity limits requests")
    func burstCapacityLimitsRequests() async {
        let config = RateLimitConfiguration(maxRequests: 100, timeWindow: 60.0, burstCapacity: 3)
        let limiter = RateLimiter(configuration: config)
        
        // First 3 requests should be allowed (burst capacity)
        for _ in 0..<3 {
            await limiter.recordRequest()
        }
        
        // Next request should be blocked (no tokens left)
        let allowed = await limiter.shouldAllowRequest()
        #expect(allowed == false)
    }
    
    @Test("Max requests limits in time window")
    func maxRequestsLimitsInTimeWindow() async {
        let config = RateLimitConfiguration(maxRequests: 3, timeWindow: 60.0, burstCapacity: 10)
        let limiter = RateLimiter(configuration: config)
        
        // Record max requests
        for _ in 0..<3 {
            await limiter.recordRequest()
        }
        
        // Next request should be blocked (max requests exceeded)
        let allowed = await limiter.shouldAllowRequest()
        #expect(allowed == false)
    }
    
    // MARK: - Status Tests
    
    @Test("Status reports correct values")
    func statusReportsCorrectValues() async {
        let config = RateLimitConfiguration(maxRequests: 10, timeWindow: 60.0, burstCapacity: 5)
        let limiter = RateLimiter(configuration: config)
        
        await limiter.recordRequest()
        await limiter.recordRequest()
        
        let status = await limiter.getStatus()
        
        #expect(status.requestsUsed == 2)
        #expect(status.requestsLimit == 10)
        #expect(status.requestsRemaining == 8)
        #expect(status.tokensAvailable == 3)
        #expect(status.tokenCapacity == 5)
        #expect(status.isLimited == false)
    }
    
    @Test("Status isLimited when at capacity")
    func statusIsLimitedWhenAtCapacity() async {
        let config = RateLimitConfiguration(maxRequests: 2, timeWindow: 60.0, burstCapacity: 10)
        let limiter = RateLimiter(configuration: config)
        
        await limiter.recordRequest()
        await limiter.recordRequest()
        
        let status = await limiter.getStatus()
        #expect(status.isLimited == true)
    }
    
    @Test("Status isLimited when no tokens")
    func statusIsLimitedWhenNoTokens() async {
        let config = RateLimitConfiguration(maxRequests: 100, timeWindow: 60.0, burstCapacity: 2)
        let limiter = RateLimiter(configuration: config)
        
        await limiter.recordRequest()
        await limiter.recordRequest()
        
        let status = await limiter.getStatus()
        #expect(status.isLimited == true)
    }
    
    @Test("Percentage used calculation")
    func percentageUsedCalculation() async {
        let config = RateLimitConfiguration(maxRequests: 10, timeWindow: 60.0, burstCapacity: 10)
        let limiter = RateLimiter(configuration: config)
        
        for _ in 0..<5 {
            await limiter.recordRequest()
        }
        
        let status = await limiter.getStatus()
        #expect(status.percentageUsed == 50.0)
    }
    
    // MARK: - Reset Tests
    
    @Test("Reset clears all state")
    func resetClearsAllState() async {
        let config = RateLimitConfiguration(maxRequests: 10, timeWindow: 60.0, burstCapacity: 5)
        let limiter = RateLimiter(configuration: config)
        
        // Use up some capacity
        for _ in 0..<3 {
            await limiter.recordRequest()
        }
        
        // Reset
        await limiter.reset()
        
        let status = await limiter.getStatus()
        #expect(status.requestsUsed == 0)
        #expect(status.tokensAvailable == 5)
    }
    
    // MARK: - Endpoint Rate Limiter Tests
    
    @Test("Endpoint rate limiter creates separate limiters")
    func endpointRateLimiterCreatesSeparateLimiters() async {
        let limiter = EndpointRateLimiter()
        
        // Record requests on different endpoints
        await limiter.recordRequest(for: "/api/v1/mint")
        await limiter.recordRequest(for: "/api/v1/mint")
        await limiter.recordRequest(for: "/api/v1/melt")
        
        let mintStatus = await limiter.getStatus(for: "/api/v1/mint")
        let meltStatus = await limiter.getStatus(for: "/api/v1/melt")
        
        #expect(mintStatus.requestsUsed == 2)
        #expect(meltStatus.requestsUsed == 1)
    }
    
    @Test("Endpoint rate limiter uses custom configurations")
    func endpointRateLimiterUsesCustomConfigurations() async {
        let strictConfig = RateLimitConfiguration(maxRequests: 5, timeWindow: 60.0, burstCapacity: 2)
        let limiter = EndpointRateLimiter(
            defaultConfiguration: .default,
            endpointConfigurations: ["/api/v1/sensitive": strictConfig]
        )
        
        let sensitiveStatus = await limiter.getStatus(for: "/api/v1/sensitive")
        let normalStatus = await limiter.getStatus(for: "/api/v1/normal")
        
        #expect(sensitiveStatus.tokenCapacity == 2)
        #expect(normalStatus.tokenCapacity == RateLimitConstants.defaultBurstCapacity)
    }
    
    @Test("Endpoint rate limiter shouldAllowRequest")
    func endpointRateLimiterShouldAllowRequest() async {
        let config = RateLimitConfiguration(maxRequests: 2, timeWindow: 60.0, burstCapacity: 10)
        let limiter = EndpointRateLimiter(defaultConfiguration: config)
        
        await limiter.recordRequest(for: "/test")
        await limiter.recordRequest(for: "/test")
        
        let allowed = await limiter.shouldAllowRequest(for: "/test")
        #expect(allowed == false)
    }
    
    @Test("Endpoint rate limiter reset specific endpoint")
    func endpointRateLimiterResetSpecificEndpoint() async {
        let limiter = EndpointRateLimiter()
        
        await limiter.recordRequest(for: "/api/v1/mint")
        await limiter.recordRequest(for: "/api/v1/melt")
        
        await limiter.reset(endpoint: "/api/v1/mint")
        
        let mintStatus = await limiter.getStatus(for: "/api/v1/mint")
        let meltStatus = await limiter.getStatus(for: "/api/v1/melt")
        
        #expect(mintStatus.requestsUsed == 0)
        #expect(meltStatus.requestsUsed == 1)
    }
    
    @Test("Endpoint rate limiter reset all endpoints")
    func endpointRateLimiterResetAllEndpoints() async {
        let limiter = EndpointRateLimiter()
        
        await limiter.recordRequest(for: "/api/v1/mint")
        await limiter.recordRequest(for: "/api/v1/melt")
        
        await limiter.reset()
        
        let mintStatus = await limiter.getStatus(for: "/api/v1/mint")
        let meltStatus = await limiter.getStatus(for: "/api/v1/melt")
        
        #expect(mintStatus.requestsUsed == 0)
        #expect(meltStatus.requestsUsed == 0)
    }
    
    // MARK: - Concurrency Tests
    
    @Test("Concurrent requests are handled safely")
    func concurrentRequestsAreHandledSafely() async {
        let config = RateLimitConfiguration(maxRequests: 100, timeWindow: 60.0, burstCapacity: 50)
        let limiter = RateLimiter(configuration: config)
        
        // Make many concurrent requests
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await limiter.recordRequest()
                }
            }
        }
        
        let status = await limiter.getStatus()
        #expect(status.requestsUsed == 20)
    }
}
