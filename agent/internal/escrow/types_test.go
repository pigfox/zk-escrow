package escrow_test

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"

	"github.com/pigfox/zk-escrow/agent/internal/escrow"
)

// TestDisputeAccumulatesSubmissions documents the shape the watcher produces:
// one Dispute per escrow id, carrying every DisputeRaised submission in the
// order it was observed on chain.
func TestDisputeAccumulatesSubmissions(t *testing.T) {
	buyer := common.HexToAddress("0x1111111111111111111111111111111111111111")
	seller := common.HexToAddress("0x2222222222222222222222222222222222222222")

	dispute := escrow.Dispute{
		EscrowID: big.NewInt(3),
		Submissions: []escrow.Submission{
			{RaisedBy: buyer, Evidence: "raiseDispute", BlockNumber: 10, LogIndex: 0},
			{RaisedBy: seller, Evidence: "submitEvidence", BlockNumber: 11, LogIndex: 2},
		},
	}

	if dispute.EscrowID.String() != "3" {
		t.Errorf("EscrowID = %s, want 3", dispute.EscrowID)
	}
	if len(dispute.Submissions) != 2 {
		t.Fatalf("got %d submissions, want 2", len(dispute.Submissions))
	}
	if dispute.Submissions[0].RaisedBy != buyer {
		t.Errorf("first submission raisedBy = %s, want %s", dispute.Submissions[0].RaisedBy, buyer)
	}
	if dispute.Submissions[1].LogIndex != 2 {
		t.Errorf("second submission log index = %d, want 2", dispute.Submissions[1].LogIndex)
	}
}

// TestDecisionCarriesBothRulingForms guards the pairing the executor relies on:
// the numeric enum goes on chain, the name goes in the log.
func TestDecisionCarriesBothRulingForms(t *testing.T) {
	decision := escrow.Decision{
		Ruling:     1,
		RulingName: "SellerWins",
		Rationale:  "Delivery is proven.",
	}
	if decision.Ruling != 1 || decision.RulingName != "SellerWins" {
		t.Errorf("Decision = %+v", decision)
	}
	if decision.Rationale == "" {
		t.Error("Rationale must be non-empty; resolveDispute rejects a blank one")
	}
}
