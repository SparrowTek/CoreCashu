import CoreCashu

// Create a token to send 100 sats to another user
let token = try await wallet.send(amount: 100, memo: "Payment for coffee")

// Serialize the token as a string to share
let tokenString = try token.serialize()
print("Send this token: \(tokenString)")

// The recipient can paste this token into their wallet to receive the funds
