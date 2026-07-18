// Package chain reads DisputeRaised events and escrow state from an
// EVM node using plain eth_getLogs and eth_call polling. It never opens a
// websocket subscription.
package chain

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/pigfox/zk-escrow/agent/internal/config"
	"github.com/pigfox/zk-escrow/agent/internal/escrow"
)

// Sentinel errors. Callers match these with errors.Is.
var (
	// ErrParseABI means the supplied ABI JSON did not parse.
	ErrParseABI = errors.New("chain: parsing escrow ABI")
	// ErrEventNotInABI means the ABI lacked the DisputeRaised event.
	ErrEventNotInABI = errors.New("chain: event missing from ABI")
	// ErrMethodNotInABI means the ABI lacked the getState method.
	ErrMethodNotInABI = errors.New("chain: method missing from ABI")
	// ErrHeadBlock means eth_blockNumber failed.
	ErrHeadBlock = errors.New("chain: fetching head block")
	// ErrFilterLogs means eth_getLogs failed.
	ErrFilterLogs = errors.New("chain: filtering logs")
	// ErrMalformedLog means a log had too few topics to be a DisputeRaised.
	ErrMalformedLog = errors.New("chain: malformed DisputeRaised log")
	// ErrDecodeLogData means the non-indexed log data did not decode.
	ErrDecodeLogData = errors.New("chain: decoding DisputeRaised data")
	// ErrPackCall means the eth_call payload could not be encoded.
	ErrPackCall = errors.New("chain: packing getState call")
	// ErrCallContract means eth_call failed.
	ErrCallContract = errors.New("chain: calling getState")
	// ErrDecodeState means the getState return data did not decode.
	ErrDecodeState = errors.New("chain: decoding getState result")
	// ErrEmptyStateResult means getState returned no values.
	ErrEmptyStateResult = errors.New("chain: getState returned no values")
	// ErrStateType means getState returned a non-uint8 value.
	ErrStateType = errors.New("chain: getState returned a non-uint8 value")
)

// Expected topic layout of DisputeRaised(uint256 indexed, address indexed, string).
const (
	// topicCount is the event signature plus two indexed parameters.
	topicCount = 3
	// topicEscrowID is the index of the escrowId topic.
	topicEscrowID = 1
	// topicRaisedBy is the index of the raisedBy topic.
	topicRaisedBy = 2
	// evidenceField is the ABI name of the non-indexed evidence argument.
	evidenceField = "evidence"
)

// EthClient is the subset of ethclient.Client the agent uses. *ethclient.Client
// satisfies it directly; tests substitute a fake.
type EthClient interface {
	// BlockNumber returns the current head block number.
	BlockNumber(ctx context.Context) (uint64, error)
	// FilterLogs performs an eth_getLogs query.
	FilterLogs(ctx context.Context, query ethereum.FilterQuery) ([]types.Log, error)
	// CallContract performs an eth_call at the given block (nil for latest).
	CallContract(ctx context.Context, call ethereum.CallMsg, blockNumber *big.Int) ([]byte, error)
}

// Chain reads escrow disputes and state from an EVM node.
type Chain struct {
	client      EthClient
	address     common.Address
	contractABI abi.ABI
	eventName   string
	stateMethod string
}

// New parses the ABI and returns a Chain bound to the escrow contract.
func New(client EthClient, address common.Address, abiJSON string) (*Chain, error) {
	parsed, err := abi.JSON(strings.NewReader(abiJSON))
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrParseABI, err)
	}
	if _, ok := parsed.Events[config.EventDisputeRaised]; !ok {
		return nil, fmt.Errorf("%w: %s", ErrEventNotInABI, config.EventDisputeRaised)
	}
	if _, ok := parsed.Methods[config.MethodGetState]; !ok {
		return nil, fmt.Errorf("%w: %s", ErrMethodNotInABI, config.MethodGetState)
	}
	return &Chain{
		client:      client,
		address:     address,
		contractABI: parsed,
		eventName:   config.EventDisputeRaised,
		stateMethod: config.MethodGetState,
	}, nil
}

// HeadBlock returns the current head block number.
func (c *Chain) HeadBlock(ctx context.Context) (uint64, error) {
	head, err := c.client.BlockNumber(ctx)
	if err != nil {
		return 0, fmt.Errorf("%w: %w", ErrHeadBlock, err)
	}
	return head, nil
}

// Disputes fetches every DisputeRaised log in [from, to] and groups the
// submissions by escrow id, preserving on-chain order.
func (c *Chain) Disputes(ctx context.Context, from, to uint64) ([]escrow.Dispute, error) {
	query := ethereum.FilterQuery{
		FromBlock: new(big.Int).SetUint64(from),
		ToBlock:   new(big.Int).SetUint64(to),
		Addresses: []common.Address{c.address},
		Topics:    [][]common.Hash{{c.contractABI.Events[c.eventName].ID}},
	}

	logs, err := c.client.FilterLogs(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrFilterLogs, err)
	}

	var order []string
	grouped := make(map[string]*escrow.Dispute, len(logs))

	for _, entry := range logs {
		submission, escrowID, err := c.decodeLog(entry)
		if err != nil {
			return nil, err
		}
		key := escrowID.String()
		dispute, seen := grouped[key]
		if !seen {
			dispute = &escrow.Dispute{EscrowID: escrowID}
			grouped[key] = dispute
			order = append(order, key)
		}
		dispute.Submissions = append(dispute.Submissions, submission)
	}

	disputes := make([]escrow.Dispute, 0, len(order))
	for _, key := range order {
		disputes = append(disputes, *grouped[key])
	}
	return disputes, nil
}

// decodeLog turns one raw log into a Submission plus its escrow id.
func (c *Chain) decodeLog(entry types.Log) (escrow.Submission, *big.Int, error) {
	if len(entry.Topics) < topicCount {
		return escrow.Submission{}, nil, fmt.Errorf("%w: got %d topics, want %d",
			ErrMalformedLog, len(entry.Topics), topicCount)
	}

	values := make(map[string]any, 1)
	if err := c.contractABI.Events[c.eventName].Inputs.NonIndexed().UnpackIntoMap(
		values, entry.Data); err != nil {
		return escrow.Submission{}, nil, fmt.Errorf("%w: %w", ErrDecodeLogData, err)
	}

	evidence, ok := values[evidenceField].(string)
	if !ok {
		return escrow.Submission{}, nil, fmt.Errorf("%w: %s is %T",
			ErrDecodeLogData, evidenceField, values[evidenceField])
	}

	return escrow.Submission{
		RaisedBy:    common.BytesToAddress(entry.Topics[topicRaisedBy].Bytes()),
		Evidence:    evidence,
		BlockNumber: entry.BlockNumber,
		LogIndex:    entry.Index,
	}, new(big.Int).SetBytes(entry.Topics[topicEscrowID].Bytes()), nil
}

// State returns the escrow's lifecycle state via a getState eth_call.
func (c *Chain) State(ctx context.Context, escrowID *big.Int) (uint8, error) {
	payload, err := c.contractABI.Pack(c.stateMethod, escrowID)
	if err != nil {
		return 0, fmt.Errorf("%w: %w", ErrPackCall, err)
	}

	returned, err := c.client.CallContract(ctx, ethereum.CallMsg{
		To:   &c.address,
		Data: payload,
	}, nil)
	if err != nil {
		return 0, fmt.Errorf("%w: %w", ErrCallContract, err)
	}

	values, err := c.contractABI.Unpack(c.stateMethod, returned)
	if err != nil {
		return 0, fmt.Errorf("%w: %w", ErrDecodeState, err)
	}
	if len(values) == 0 {
		return 0, ErrEmptyStateResult
	}
	state, ok := values[0].(uint8)
	if !ok {
		return 0, fmt.Errorf("%w: %T", ErrStateType, values[0])
	}
	return state, nil
}
