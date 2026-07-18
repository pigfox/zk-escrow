// Package escrow holds the value types shared between the chain watcher, the
// AI arbiter and the transaction executor. It deliberately has no behaviour
// and no dependencies beyond go-ethereum's address type, so every other
// internal package can import it without creating a cycle.
package escrow

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
)

// Submission is one party's DisputeRaised evidence payload. Both
// raiseDispute() and submitEvidence() emit DisputeRaised, so a single escrow
// accumulates one Submission per party action.
type Submission struct {
	// RaisedBy is the indexed `raisedBy` topic: buyer or seller.
	RaisedBy common.Address
	// Evidence is the non-indexed `evidence` string from the log data.
	Evidence string
	// BlockNumber is the block the log was mined in, used for ordering.
	BlockNumber uint64
	// LogIndex disambiguates submissions within a single block.
	LogIndex uint
}

// Dispute is every Submission gathered for one escrow id.
type Dispute struct {
	// EscrowID is the indexed `escrowId` topic.
	EscrowID *big.Int
	// Submissions are in the order they were observed on chain.
	Submissions []Submission
}

// Decision is the arbiter's verdict, ready to be written on chain.
type Decision struct {
	// Ruling is the Solidity `Ruling` enum value: 0 BuyerWins, 1 SellerWins.
	Ruling uint8
	// RulingName is the human-readable form the model returned.
	RulingName string
	// Rationale is emitted verbatim by resolveDispute.
	Rationale string
}
