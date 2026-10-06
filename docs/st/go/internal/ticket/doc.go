// Package ticket is the core of the ticket QR API (clean architecture: entities and use cases): the
// ticket code rule, VerifyAndGrant (verify a certificate image, then grant a ticket) and the business
// errors. It does no I/O itself and depends on no other internal package; the verification server is
// reached through the Verifier interface defined here and implemented by package analyzer.
package ticket
