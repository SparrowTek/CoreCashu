//
//  CashuEnvironment.swift
//  CashuKit
//
//  Created by Thomas Rademaker on 6/27/25.
//

@CashuActor
class CashuEnvironment {
    static var current: CashuEnvironment = .init()
    private(set) var routerDelegate: CashuRouterDelegate

    private init() {
        self.routerDelegate = CashuRouterDelegate()
    }

    /// Swap the router delegate. Test-only: production code should never need this. The
    /// returned delegate is used by every NUT-level service for retry, idempotency, rate
    /// limiting, and circuit breaking, so changing it mid-flight will affect any router
    /// already initialized.
    func setRouterDelegate(_ delegate: CashuRouterDelegate) {
        self.routerDelegate = delegate
    }
}
