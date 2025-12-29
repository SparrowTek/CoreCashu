import CoreCashu

// Receive a token from another user
let receivedTokenString = "cashuA..." // Token string received from sender

// Process and swap the token
let receivedProofs = try await wallet.receive(token: receivedTokenString)

// The proofs are now in the wallet
print("Received \(receivedProofs.count) proofs")
let totalReceived = receivedProofs.reduce(0) { $0 + $1.amount }
print("Total received: \(totalReceived) sats")

// Check new balance
let newBalance = try await wallet.balance
print("New balance: \(newBalance) sats")
