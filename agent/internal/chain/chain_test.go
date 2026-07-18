package chain

import (
	"context"
	"errors"
	"math/big"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/pigfox/zk-escrow/agent/internal/config"
)

var (
	contractAddr = common.HexToAddress("0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
	buyerAddr    = common.HexToAddress("0x1111111111111111111111111111111111111111")
	sellerAddr   = common.HexToAddress("0x2222222222222222222222222222222222222222")
)

// fakeEth is a scripted EthClient.
type fakeEth struct {
	head     uint64
	headErr  error
	logs     []types.Log
	logsErr  error
	callData []byte
	callErr  error

	lastQuery ethereum.FilterQuery
	lastCall  ethereum.CallMsg
}

func (f *fakeEth) BlockNumber(context.Context) (uint64, error) {
	return f.head, f.headErr
}

func (f *fakeEth) FilterLogs(_ context.Context, q ethereum.FilterQuery) ([]types.Log, error) {
	f.lastQuery = q
	return f.logs, f.logsErr
}

func (f *fakeEth) CallContract(
	_ context.Context, call ethereum.CallMsg, _ *big.Int,
) ([]byte, error) {
	f.lastCall = call
	return f.callData, f.callErr
}

// newTestChain builds a Chain over the production ABI.
func newTestChain(t *testing.T, client EthClient) *Chain {
	t.Helper()
	c, err := New(client, contractAddr, config.EscrowABIJSON)
	if err != nil {
		t.Fatalf("New() unexpected error: %v", err)
	}
	return c
}

// disputeLog builds a well-formed DisputeRaised log.
func disputeLog(t *testing.T, escrowID int64, from common.Address, evidence string,
	block uint64, index uint,
) types.Log {
	t.Helper()
	parsed, err := abi.JSON(strings.NewReader(config.EscrowABIJSON))
	if err != nil {
		t.Fatalf("parsing ABI: %v", err)
	}
	event := parsed.Events[config.EventDisputeRaised]
	data, err := event.Inputs.NonIndexed().Pack(evidence)
	if err != nil {
		t.Fatalf("packing evidence: %v", err)
	}
	return types.Log{
		Address: contractAddr,
		Topics: []common.Hash{
			event.ID,
			common.BigToHash(big.NewInt(escrowID)),
			common.BytesToHash(from.Bytes()),
		},
		Data:        data,
		BlockNumber: block,
		Index:       index,
	}
}

func TestNew(t *testing.T) {
	tests := []struct {
		name    string
		abiJSON string
		wantErr error
	}{
		{
			name:    "production abi parses",
			abiJSON: config.EscrowABIJSON,
		},
		{
			name:    "malformed json",
			abiJSON: `{not json`,
			wantErr: ErrParseABI,
		},
		{
			name: "abi without the DisputeRaised event",
			abiJSON: `[{"type":"function","name":"getState","stateMutability":"view",
				"inputs":[{"name":"escrowId","type":"uint256"}],
				"outputs":[{"name":"","type":"uint8"}]}]`,
			wantErr: ErrEventNotInABI,
		},
		{
			name: "abi without the getState method",
			abiJSON: `[{"type":"event","name":"DisputeRaised","anonymous":false,"inputs":[
				{"name":"escrowId","type":"uint256","indexed":true},
				{"name":"raisedBy","type":"address","indexed":true},
				{"name":"evidence","type":"string","indexed":false}]}]`,
			wantErr: ErrMethodNotInABI,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := New(&fakeEth{}, contractAddr, tt.abiJSON)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("New() error = %v, want %v", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("New() unexpected error: %v", err)
			}
		})
	}
}

func TestHeadBlock(t *testing.T) {
	t.Run("success", func(t *testing.T) {
		c := newTestChain(t, &fakeEth{head: 4242})
		head, err := c.HeadBlock(t.Context())
		if err != nil {
			t.Fatalf("HeadBlock() unexpected error: %v", err)
		}
		if head != 4242 {
			t.Errorf("HeadBlock() = %d, want 4242", head)
		}
	})

	t.Run("rpc failure", func(t *testing.T) {
		c := newTestChain(t, &fakeEth{headErr: errors.New("rpc down")})
		if _, err := c.HeadBlock(t.Context()); !errors.Is(err, ErrHeadBlock) {
			t.Fatalf("HeadBlock() error = %v, want %v", err, ErrHeadBlock)
		}
	})
}

// TestDisputesGroupsByEscrowID covers the multi-submission requirement: both
// raiseDispute and submitEvidence emit DisputeRaised, so one escrow can appear
// several times and must be collapsed into a single Dispute.
func TestDisputesGroupsByEscrowID(t *testing.T) {
	fake := &fakeEth{logs: []types.Log{
		disputeLog(t, 1, buyerAddr, "buyer: nothing arrived", 100, 0),
		disputeLog(t, 2, sellerAddr, "other escrow", 100, 1),
		disputeLog(t, 1, sellerAddr, "seller: tracking shows delivered", 101, 0),
		disputeLog(t, 1, buyerAddr, "buyer: tracking is forged", 102, 3),
	}}
	c := newTestChain(t, fake)

	disputes, err := c.Disputes(t.Context(), 100, 102)
	if err != nil {
		t.Fatalf("Disputes() unexpected error: %v", err)
	}
	if len(disputes) != 2 {
		t.Fatalf("got %d disputes, want 2", len(disputes))
	}

	first := disputes[0]
	if first.EscrowID.String() != "1" {
		t.Errorf("first dispute escrow id = %s, want 1", first.EscrowID)
	}
	if len(first.Submissions) != 3 {
		t.Fatalf("escrow 1 has %d submissions, want 3", len(first.Submissions))
	}
	if first.Submissions[0].RaisedBy != buyerAddr {
		t.Errorf("submission 0 raisedBy = %s, want %s", first.Submissions[0].RaisedBy, buyerAddr)
	}
	if first.Submissions[1].Evidence != "seller: tracking shows delivered" {
		t.Errorf("submission 1 evidence = %q", first.Submissions[1].Evidence)
	}
	if first.Submissions[2].BlockNumber != 102 || first.Submissions[2].LogIndex != 3 {
		t.Errorf("submission 2 position = %d/%d, want 102/3",
			first.Submissions[2].BlockNumber, first.Submissions[2].LogIndex)
	}
	if disputes[1].EscrowID.String() != "2" {
		t.Errorf("second dispute escrow id = %s, want 2", disputes[1].EscrowID)
	}

	// The query must be scoped to the contract and the event signature.
	if len(fake.lastQuery.Addresses) != 1 || fake.lastQuery.Addresses[0] != contractAddr {
		t.Errorf("query addresses = %v", fake.lastQuery.Addresses)
	}
	if fake.lastQuery.FromBlock.Uint64() != 100 || fake.lastQuery.ToBlock.Uint64() != 102 {
		t.Errorf("query range = %v..%v", fake.lastQuery.FromBlock, fake.lastQuery.ToBlock)
	}
	if len(fake.lastQuery.Topics) != 1 || len(fake.lastQuery.Topics[0]) != 1 {
		t.Fatalf("query topics = %v", fake.lastQuery.Topics)
	}
}

func TestDisputesEmpty(t *testing.T) {
	c := newTestChain(t, &fakeEth{})
	disputes, err := c.Disputes(t.Context(), 1, 2)
	if err != nil {
		t.Fatalf("Disputes() unexpected error: %v", err)
	}
	if len(disputes) != 0 {
		t.Errorf("got %d disputes, want 0", len(disputes))
	}
}

func TestDisputesErrors(t *testing.T) {
	tests := []struct {
		name    string
		fake    *fakeEth
		abiJSON string
		wantErr error
	}{
		{
			name:    "eth_getLogs fails",
			fake:    &fakeEth{logsErr: errors.New("range too wide")},
			wantErr: ErrFilterLogs,
		},
		{
			name: "log has too few topics",
			fake: &fakeEth{logs: []types.Log{{
				Address: contractAddr,
				Topics:  []common.Hash{{}, {}},
			}}},
			wantErr: ErrMalformedLog,
		},
		{
			name: "log data is not decodable",
			fake: &fakeEth{logs: []types.Log{{
				Address: contractAddr,
				Topics:  []common.Hash{{}, {}, {}},
				Data:    []byte{0x01, 0x02, 0x03},
			}}},
			wantErr: ErrDecodeLogData,
		},
		{
			name: "evidence field is not a string",
			fake: &fakeEth{logs: []types.Log{{
				Address: contractAddr,
				Topics:  []common.Hash{{}, {}, {}},
				Data:    common.LeftPadBytes(big.NewInt(9).Bytes(), 32),
			}}},
			abiJSON: `[
				{"type":"event","name":"DisputeRaised","anonymous":false,"inputs":[
					{"name":"escrowId","type":"uint256","indexed":true},
					{"name":"raisedBy","type":"address","indexed":true},
					{"name":"evidence","type":"uint256","indexed":false}]},
				{"type":"function","name":"getState","stateMutability":"view",
					"inputs":[{"name":"escrowId","type":"uint256"}],
					"outputs":[{"name":"","type":"uint8"}]}]`,
			wantErr: ErrDecodeLogData,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			abiJSON := tt.abiJSON
			if abiJSON == "" {
				abiJSON = config.EscrowABIJSON
			}
			c, err := New(tt.fake, contractAddr, abiJSON)
			if err != nil {
				t.Fatalf("New() unexpected error: %v", err)
			}
			if _, err := c.Disputes(t.Context(), 1, 2); !errors.Is(err, tt.wantErr) {
				t.Fatalf("Disputes() error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

func TestStateSuccess(t *testing.T) {
	fake := &fakeEth{callData: []byte{config.StateDisputed}}
	fake.callData = common.LeftPadBytes([]byte{config.StateDisputed}, 32)
	c := newTestChain(t, fake)

	state, err := c.State(t.Context(), big.NewInt(1))
	if err != nil {
		t.Fatalf("State() unexpected error: %v", err)
	}
	if state != config.StateDisputed {
		t.Errorf("State() = %d, want %d", state, config.StateDisputed)
	}
	if fake.lastCall.To == nil || *fake.lastCall.To != contractAddr {
		t.Errorf("call target = %v, want %s", fake.lastCall.To, contractAddr)
	}
	if len(fake.lastCall.Data) == 0 {
		t.Error("call data must carry the packed getState selector")
	}
}

func TestStateErrors(t *testing.T) {
	// An ABI whose getState returns nothing, and one whose getState returns a
	// uint256 -- these make the "no values" and "wrong type" branches
	// reachable without changing the production ABI.
	const noOutputABI = `[
		{"type":"event","name":"DisputeRaised","anonymous":false,"inputs":[
			{"name":"escrowId","type":"uint256","indexed":true},
			{"name":"raisedBy","type":"address","indexed":true},
			{"name":"evidence","type":"string","indexed":false}]},
		{"type":"function","name":"getState","stateMutability":"view",
			"inputs":[{"name":"escrowId","type":"uint256"}],"outputs":[]}]`

	const uint256OutputABI = `[
		{"type":"event","name":"DisputeRaised","anonymous":false,"inputs":[
			{"name":"escrowId","type":"uint256","indexed":true},
			{"name":"raisedBy","type":"address","indexed":true},
			{"name":"evidence","type":"string","indexed":false}]},
		{"type":"function","name":"getState","stateMutability":"view",
			"inputs":[{"name":"escrowId","type":"uint256"}],
			"outputs":[{"name":"","type":"uint256"}]}]`

	tests := []struct {
		name    string
		abiJSON string
		fake    *fakeEth
		mutate  func(c *Chain)
		wantErr error
	}{
		{
			name:    "packing the call fails",
			fake:    &fakeEth{},
			mutate:  func(c *Chain) { c.stateMethod = "noSuchMethod" },
			wantErr: ErrPackCall,
		},
		{
			name:    "eth_call fails",
			fake:    &fakeEth{callErr: errors.New("execution reverted")},
			wantErr: ErrCallContract,
		},
		{
			name:    "return data is not decodable",
			fake:    &fakeEth{callData: []byte{0xff}},
			wantErr: ErrDecodeState,
		},
		{
			name:    "getState returns no values",
			abiJSON: noOutputABI,
			fake:    &fakeEth{callData: nil},
			wantErr: ErrEmptyStateResult,
		},
		{
			name:    "getState returns a non-uint8",
			abiJSON: uint256OutputABI,
			fake:    &fakeEth{callData: common.LeftPadBytes([]byte{5}, 32)},
			wantErr: ErrStateType,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			abiJSON := tt.abiJSON
			if abiJSON == "" {
				abiJSON = config.EscrowABIJSON
			}
			c, err := New(tt.fake, contractAddr, abiJSON)
			if err != nil {
				t.Fatalf("New() unexpected error: %v", err)
			}
			if tt.mutate != nil {
				tt.mutate(c)
			}
			if _, err := c.State(t.Context(), big.NewInt(1)); !errors.Is(err, tt.wantErr) {
				t.Fatalf("State() error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}
