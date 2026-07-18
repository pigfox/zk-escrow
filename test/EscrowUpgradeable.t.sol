// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {BaseTest} from "./Base.t.sol";
import {EscrowUpgradeable} from "../src/EscrowUpgradeable.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";
import {MaliciousReceiver} from "./mocks/MaliciousReceiver.sol";

/// @title EscrowUpgradeableTest
/// @notice Covers every function, every custom error and every state-machine
///         branch of EscrowUpgradeable.
contract EscrowUpgradeableTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_Initialize_SetsState() public view {
        assertEq(address(escrow.verifier()), address(verifier), "verifier");
        assertEq(escrow.owner(), owner, "owner");
        assertEq(escrow.nextEscrowId(), 0, "nextEscrowId");
        assertEq(escrow.totalPendingWithdrawals(), 0, "totalPendingWithdrawals");
    }

    function test_Initialize_RevertsOnZeroVerifier() public {
        EscrowUpgradeable impl = new EscrowUpgradeable();
        bytes memory initData = abi.encodeCall(EscrowUpgradeable.initialize, (address(0), owner));
        vm.expectRevert(EscrowUpgradeable.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertsOnZeroOwner() public {
        EscrowUpgradeable impl = new EscrowUpgradeable();
        bytes memory initData =
            abi.encodeCall(EscrowUpgradeable.initialize, (address(verifier), address(0)));
        vm.expectRevert(EscrowUpgradeable.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertsOnSecondCall() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.initialize(address(verifier), owner);
    }

    function test_Initialize_ImplementationIsDisabled() public {
        EscrowUpgradeable impl = new EscrowUpgradeable();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(verifier), owner);
    }

    /*//////////////////////////////////////////////////////////////
                             CREATE ESCROW
    //////////////////////////////////////////////////////////////*/

    function test_CreateEscrow_Succeeds() public {
        vm.expectEmit(true, true, true, true, address(escrow));
        emit EscrowUpgradeable.EscrowCreated(0, buyer, seller, arbiter, AMOUNT, COMMITMENT);

        uint256 escrowId = _create();

        assertEq(escrowId, 0, "escrowId");
        assertEq(escrow.nextEscrowId(), 1, "nextEscrowId advanced");

        EscrowUpgradeable.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.buyer, buyer, "buyer");
        assertEq(e.seller, seller, "seller");
        assertEq(e.arbiter, arbiter, "arbiter");
        assertEq(e.amount, AMOUNT, "amount");
        assertEq(e.commitment, COMMITMENT, "commitment");
        assertTrue(e.state == EscrowUpgradeable.State.Created, "state");
    }

    function test_CreateEscrow_IdsIncrementIndependently() public {
        uint256 first = _create();
        uint256 second = _create();
        assertEq(first, 0, "first id");
        assertEq(second, 1, "second id");
    }

    function test_CreateEscrow_RevertsOnZeroSeller() public {
        vm.prank(buyer);
        vm.expectRevert(EscrowUpgradeable.ZeroAddress.selector);
        escrow.createEscrow(address(0), arbiter, AMOUNT, COMMITMENT);
    }

    function test_CreateEscrow_RevertsOnZeroArbiter() public {
        vm.prank(buyer);
        vm.expectRevert(EscrowUpgradeable.ZeroAddress.selector);
        escrow.createEscrow(seller, address(0), AMOUNT, COMMITMENT);
    }

    function test_CreateEscrow_RevertsWhenSellerIsBuyer() public {
        vm.prank(buyer);
        vm.expectRevert(EscrowUpgradeable.DuplicateParty.selector);
        escrow.createEscrow(buyer, arbiter, AMOUNT, COMMITMENT);
    }

    function test_CreateEscrow_RevertsWhenArbiterIsBuyer() public {
        vm.prank(buyer);
        vm.expectRevert(EscrowUpgradeable.DuplicateParty.selector);
        escrow.createEscrow(seller, buyer, AMOUNT, COMMITMENT);
    }

    function test_CreateEscrow_RevertsWhenArbiterIsSeller() public {
        vm.prank(buyer);
        vm.expectRevert(EscrowUpgradeable.DuplicateParty.selector);
        escrow.createEscrow(seller, seller, AMOUNT, COMMITMENT);
    }

    function test_CreateEscrow_RevertsOnZeroAmount() public {
        vm.prank(buyer);
        vm.expectRevert(EscrowUpgradeable.ZeroAmount.selector);
        escrow.createEscrow(seller, arbiter, 0, COMMITMENT);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUND
    //////////////////////////////////////////////////////////////*/

    function test_Fund_Succeeds() public {
        uint256 escrowId = _create();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit EscrowUpgradeable.EscrowFunded(escrowId, buyer, AMOUNT);

        vm.prank(buyer);
        escrow.fund{value: AMOUNT}(escrowId);

        assertTrue(escrow.getState(escrowId) == EscrowUpgradeable.State.Funded, "state");
        assertEq(address(escrow).balance, AMOUNT, "contract balance");
    }

    function test_Fund_RevertsForUnknownEscrow() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.EscrowDoesNotExist.selector, 42));
        escrow.fund{value: AMOUNT}(42);
    }

    function test_Fund_RevertsWhenNotBuyer() public {
        uint256 escrowId = _create();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.NotAuthorized.selector, stranger));
        escrow.fund{value: AMOUNT}(escrowId);
    }

    function test_Fund_RevertsOnWrongAmount() public {
        uint256 escrowId = _create();
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(EscrowUpgradeable.IncorrectAmount.selector, AMOUNT, 0.5 ether)
        );
        escrow.fund{value: 0.5 ether}(escrowId);
    }

    function test_Fund_RevertsWhenAlreadyFunded() public {
        uint256 escrowId = _createAndFund();
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowUpgradeable.InvalidState.selector,
                escrowId,
                EscrowUpgradeable.State.Created,
                EscrowUpgradeable.State.Funded
            )
        );
        escrow.fund{value: AMOUNT}(escrowId);
    }

    /*//////////////////////////////////////////////////////////////
                                 RELEASE
    //////////////////////////////////////////////////////////////*/

    function test_Release_Succeeds() public {
        uint256 escrowId = _createAndFund();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit EscrowUpgradeable.WithdrawalCredited(seller, AMOUNT, AMOUNT);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit EscrowUpgradeable.EscrowReleased(escrowId, seller, AMOUNT, NULLIFIER);

        _release(escrowId, NULLIFIER);

        assertTrue(escrow.getState(escrowId) == EscrowUpgradeable.State.Released, "state");
        assertEq(escrow.pendingWithdrawals(seller), AMOUNT, "seller credited");
        assertEq(escrow.totalPendingWithdrawals(), AMOUNT, "total");
        assertTrue(escrow.nullifierUsed(NULLIFIER), "nullifier spent");
    }

    function test_Release_IsPermissionless() public {
        // The proof authorizes, not the caller: a stranger holding a valid
        // proof can settle the escrow, and the money still goes to the seller.
        uint256 escrowId = _createAndFund();
        vm.prank(stranger);
        _release(escrowId, NULLIFIER);
        assertEq(escrow.pendingWithdrawals(seller), AMOUNT, "seller credited");
        assertEq(escrow.pendingWithdrawals(stranger), 0, "caller gets nothing");
    }

    function test_Release_RevertsForUnknownEscrow() public {
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.EscrowDoesNotExist.selector, 7));
        _release(7, NULLIFIER);
    }

    function test_Release_RevertsWhenNotFunded() public {
        uint256 escrowId = _create();
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowUpgradeable.InvalidState.selector,
                escrowId,
                EscrowUpgradeable.State.Funded,
                EscrowUpgradeable.State.Created
            )
        );
        _release(escrowId, NULLIFIER);
    }

    function test_Release_RevertsOnInvalidProof() public {
        uint256 escrowId = _createAndFund();
        verifier.setShouldVerify(false);
        vm.expectRevert(EscrowUpgradeable.InvalidProof.selector);
        _release(escrowId, NULLIFIER);
    }

    function test_Release_RevertsOnReusedNullifier() public {
        uint256 first = _createAndFund();
        _release(first, NULLIFIER);

        uint256 second = _createAndFund();
        vm.expectRevert(
            abi.encodeWithSelector(EscrowUpgradeable.NullifierAlreadyUsed.selector, NULLIFIER)
        );
        _release(second, NULLIFIER);
    }

    function test_Release_DoesNotCreditArbiter() public {
        uint256 escrowId = _createAndFund();
        _release(escrowId, NULLIFIER);
        assertEq(escrow.pendingWithdrawals(arbiter), 0, "arbiter uncredited");
    }

    /*//////////////////////////////////////////////////////////////
                                 REFUND
    //////////////////////////////////////////////////////////////*/

    function test_Refund_Succeeds() public {
        uint256 escrowId = _createAndFund();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit EscrowUpgradeable.EscrowRefunded(escrowId, buyer, AMOUNT);

        vm.prank(seller);
        escrow.refund(escrowId);

        assertTrue(escrow.getState(escrowId) == EscrowUpgradeable.State.Refunded, "state");
        assertEq(escrow.pendingWithdrawals(buyer), AMOUNT, "buyer credited");
    }

    function test_Refund_RevertsForUnknownEscrow() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.EscrowDoesNotExist.selector, 3));
        escrow.refund(3);
    }

    function test_Refund_RevertsWhenNotSeller() public {
        uint256 escrowId = _createAndFund();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.NotAuthorized.selector, buyer));
        escrow.refund(escrowId);
    }

    function test_Refund_RevertsWhenNotFunded() public {
        uint256 escrowId = _create();
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowUpgradeable.InvalidState.selector,
                escrowId,
                EscrowUpgradeable.State.Funded,
                EscrowUpgradeable.State.Created
            )
        );
        escrow.refund(escrowId);
    }

    /*//////////////////////////////////////////////////////////////
                              RAISE DISPUTE
    //////////////////////////////////////////////////////////////*/

    function test_RaiseDispute_ByBuyer() public {
        uint256 escrowId = _createAndFund();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit EscrowUpgradeable.DisputeRaised(escrowId, buyer, "goods never arrived");

        vm.prank(buyer);
        escrow.raiseDispute(escrowId, "goods never arrived");

        assertTrue(escrow.getState(escrowId) == EscrowUpgradeable.State.Disputed, "state");
    }

    function test_RaiseDispute_BySeller() public {
        uint256 escrowId = _createAndFund();
        vm.prank(seller);
        escrow.raiseDispute(escrowId, "shipped with tracking 1Z999");
        assertTrue(escrow.getState(escrowId) == EscrowUpgradeable.State.Disputed, "state");
    }

    function test_RaiseDispute_RevertsForUnknownEscrow() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.EscrowDoesNotExist.selector, 9));
        escrow.raiseDispute(9, "evidence");
    }

    function test_RaiseDispute_RevertsForThirdParty() public {
        uint256 escrowId = _createAndFund();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.NotAuthorized.selector, stranger));
        escrow.raiseDispute(escrowId, "evidence");
    }

    function test_RaiseDispute_RevertsForArbiter() public {
        // The arbiter judges disputes; it does not start them.
        uint256 escrowId = _createAndFund();
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.NotAuthorized.selector, arbiter));
        escrow.raiseDispute(escrowId, "evidence");
    }

    function test_RaiseDispute_RevertsOnEmptyEvidence() public {
        uint256 escrowId = _createAndFund();
        vm.prank(buyer);
        vm.expectRevert(EscrowUpgradeable.EmptyEvidence.selector);
        escrow.raiseDispute(escrowId, "");
    }

    function test_RaiseDispute_RevertsWhenNotFunded() public {
        uint256 escrowId = _create();
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowUpgradeable.InvalidState.selector,
                escrowId,
                EscrowUpgradeable.State.Funded,
                EscrowUpgradeable.State.Created
            )
        );
        escrow.raiseDispute(escrowId, "evidence");
    }

    /*//////////////////////////////////////////////////////////////
                             SUBMIT EVIDENCE
    //////////////////////////////////////////////////////////////*/

    function test_SubmitEvidence_ByBothParties() public {
        uint256 escrowId = _createFundAndDispute();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit EscrowUpgradeable.DisputeRaised(escrowId, seller, "tracking says delivered");
        vm.prank(seller);
        escrow.submitEvidence(escrowId, "tracking says delivered");

        vm.prank(buyer);
        escrow.submitEvidence(escrowId, "package was empty");

        // Submitting evidence never moves the escrow out of Disputed.
        assertTrue(escrow.getState(escrowId) == EscrowUpgradeable.State.Disputed, "state");
    }

    function test_SubmitEvidence_RevertsForUnknownEscrow() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.EscrowDoesNotExist.selector, 11));
        escrow.submitEvidence(11, "evidence");
    }

    function test_SubmitEvidence_RevertsWhenNotDisputed() public {
        uint256 escrowId = _createAndFund();
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowUpgradeable.InvalidState.selector,
                escrowId,
                EscrowUpgradeable.State.Disputed,
                EscrowUpgradeable.State.Funded
            )
        );
        escrow.submitEvidence(escrowId, "evidence");
    }

    function test_SubmitEvidence_RevertsForThirdParty() public {
        uint256 escrowId = _createFundAndDispute();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.NotAuthorized.selector, stranger));
        escrow.submitEvidence(escrowId, "evidence");
    }

    function test_SubmitEvidence_RevertsOnEmptyEvidence() public {
        uint256 escrowId = _createFundAndDispute();
        vm.prank(seller);
        vm.expectRevert(EscrowUpgradeable.EmptyEvidence.selector);
        escrow.submitEvidence(escrowId, "");
    }

    /*//////////////////////////////////////////////////////////////
                            RESOLVE DISPUTE
    //////////////////////////////////////////////////////////////*/

    function test_ResolveDispute_BuyerWins() public {
        uint256 escrowId = _createFundAndDispute();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit EscrowUpgradeable.DisputeResolved(
            escrowId, arbiter, EscrowUpgradeable.Ruling.BuyerWins, buyer, AMOUNT, "no delivery proof"
        );

        vm.prank(arbiter);
        escrow.resolveDispute(escrowId, EscrowUpgradeable.Ruling.BuyerWins, "no delivery proof");

        assertTrue(escrow.getState(escrowId) == EscrowUpgradeable.State.Resolved, "state");
        assertEq(escrow.pendingWithdrawals(buyer), AMOUNT, "buyer credited");
        assertEq(escrow.pendingWithdrawals(seller), 0, "seller uncredited");
        assertEq(escrow.pendingWithdrawals(arbiter), 0, "arbiter uncredited");
    }

    function test_ResolveDispute_SellerWins() public {
        uint256 escrowId = _createFundAndDispute();

        vm.prank(arbiter);
        escrow.resolveDispute(escrowId, EscrowUpgradeable.Ruling.SellerWins, "tracking confirms");

        assertTrue(escrow.getState(escrowId) == EscrowUpgradeable.State.Resolved, "state");
        assertEq(escrow.pendingWithdrawals(seller), AMOUNT, "seller credited");
        assertEq(escrow.pendingWithdrawals(buyer), 0, "buyer uncredited");
        assertEq(escrow.pendingWithdrawals(arbiter), 0, "arbiter uncredited");
    }

    function test_ResolveDispute_RevertsForUnknownEscrow() public {
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.EscrowDoesNotExist.selector, 5));
        escrow.resolveDispute(5, EscrowUpgradeable.Ruling.BuyerWins, "rationale");
    }

    function test_ResolveDispute_RevertsWhenNotArbiter() public {
        uint256 escrowId = _createFundAndDispute();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.NotAuthorized.selector, buyer));
        escrow.resolveDispute(escrowId, EscrowUpgradeable.Ruling.BuyerWins, "rationale");
    }

    function test_ResolveDispute_RevertsForOwnerWhoIsNotArbiter() public {
        // Being able to upgrade the contract does not make you its judge.
        uint256 escrowId = _createFundAndDispute();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.NotAuthorized.selector, owner));
        escrow.resolveDispute(escrowId, EscrowUpgradeable.Ruling.SellerWins, "rationale");
    }

    function test_ResolveDispute_RevertsWhenNotDisputed() public {
        uint256 escrowId = _createAndFund();
        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowUpgradeable.InvalidState.selector,
                escrowId,
                EscrowUpgradeable.State.Disputed,
                EscrowUpgradeable.State.Funded
            )
        );
        escrow.resolveDispute(escrowId, EscrowUpgradeable.Ruling.BuyerWins, "rationale");
    }

    function test_ResolveDispute_RevertsOnEmptyRationale() public {
        uint256 escrowId = _createFundAndDispute();
        vm.prank(arbiter);
        vm.expectRevert(EscrowUpgradeable.EmptyRationale.selector);
        escrow.resolveDispute(escrowId, EscrowUpgradeable.Ruling.BuyerWins, "");
    }

    function test_ResolveDispute_CannotBeResolvedTwice() public {
        uint256 escrowId = _createFundAndDispute();
        vm.prank(arbiter);
        escrow.resolveDispute(escrowId, EscrowUpgradeable.Ruling.BuyerWins, "first");

        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowUpgradeable.InvalidState.selector,
                escrowId,
                EscrowUpgradeable.State.Disputed,
                EscrowUpgradeable.State.Resolved
            )
        );
        escrow.resolveDispute(escrowId, EscrowUpgradeable.Ruling.SellerWins, "second");
    }

    /// @dev The arbiter of one escrow has no authority over another.
    function test_ResolveDispute_ArbiterIsPerEscrow() public {
        uint256 escrowId = _createFundAndDispute();

        address otherArbiter = makeAddr("otherArbiter");
        vm.prank(buyer);
        uint256 other = escrow.createEscrow(seller, otherArbiter, AMOUNT, COMMITMENT);
        vm.prank(buyer);
        escrow.fund{value: AMOUNT}(other);
        vm.prank(buyer);
        escrow.raiseDispute(other, "evidence");

        vm.prank(otherArbiter);
        vm.expectRevert(
            abi.encodeWithSelector(EscrowUpgradeable.NotAuthorized.selector, otherArbiter)
        );
        escrow.resolveDispute(escrowId, EscrowUpgradeable.Ruling.SellerWins, "not my escrow");
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw_Succeeds() public {
        uint256 escrowId = _createAndFund();
        _release(escrowId, NULLIFIER);

        uint256 before = seller.balance;

        vm.expectEmit(true, true, true, true, address(escrow));
        emit EscrowUpgradeable.Withdrawn(seller, AMOUNT);

        vm.prank(seller);
        escrow.withdraw();

        assertEq(seller.balance, before + AMOUNT, "seller paid");
        assertEq(escrow.pendingWithdrawals(seller), 0, "balance zeroed");
        assertEq(escrow.totalPendingWithdrawals(), 0, "total zeroed");
        assertEq(address(escrow).balance, 0, "contract drained");
    }

    function test_Withdraw_RevertsWithNothingPending() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(EscrowUpgradeable.NothingToWithdraw.selector, stranger)
        );
        escrow.withdraw();
    }

    function test_Withdraw_RevertsOnSecondCall() public {
        uint256 escrowId = _createAndFund();
        _release(escrowId, NULLIFIER);

        vm.prank(seller);
        escrow.withdraw();

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.NothingToWithdraw.selector, seller));
        escrow.withdraw();
    }

    function test_Withdraw_AccumulatesAcrossEscrows() public {
        uint256 first = _createAndFund();
        _release(first, NULLIFIER);
        uint256 second = _createAndFund();
        _release(second, uint256(keccak256("nullifier-2")));

        assertEq(escrow.pendingWithdrawals(seller), 2 * AMOUNT, "accumulated");

        uint256 before = seller.balance;
        vm.prank(seller);
        escrow.withdraw();
        assertEq(seller.balance, before + 2 * AMOUNT, "paid in one go");
    }

    function test_Withdraw_RevertsWhenRecipientRejectsEth() public {
        MaliciousReceiver receiver = new MaliciousReceiver(escrow);
        vm.deal(address(receiver), 10 ether);

        uint256 escrowId = receiver.createEscrow(seller, arbiter, AMOUNT, COMMITMENT);
        receiver.fund{value: AMOUNT}(escrowId);

        vm.prank(seller);
        escrow.refund(escrowId);
        assertEq(escrow.pendingWithdrawals(address(receiver)), AMOUNT, "credited");

        receiver.setAcceptEth(false);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowUpgradeable.TransferFailed.selector, address(receiver), AMOUNT
            )
        );
        receiver.attack();

        // The revert rolled the whole withdrawal back, so the credit survives.
        assertEq(escrow.pendingWithdrawals(address(receiver)), AMOUNT, "credit intact");
        assertEq(address(escrow).balance, AMOUNT, "funds intact");
    }

    /*//////////////////////////////////////////////////////////////
                               REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw_ReentrancyIsBlocked() public {
        MaliciousReceiver attacker = new MaliciousReceiver(escrow);
        vm.deal(address(attacker), 10 ether);

        // The attacker is the buyer on its own escrow and gets refunded, so it
        // has a legitimate 1 ether credit to withdraw.
        uint256 attackerEscrow = attacker.createEscrow(seller, arbiter, AMOUNT, COMMITMENT);
        attacker.fund{value: AMOUNT}(attackerEscrow);
        vm.prank(seller);
        escrow.refund(attackerEscrow);

        // A second, unrelated escrow leaves extra ETH in the contract — the
        // funds a successful drain would steal.
        uint256 victimEscrow = _createAndFund();

        uint256 contractBalanceBefore = address(escrow).balance;
        assertEq(contractBalanceBefore, 2 * AMOUNT, "two escrows funded");

        uint256 attackerBefore = address(attacker).balance;
        attacker.attack();

        assertEq(attacker.reentryAttempts(), 1, "reentry was attempted");
        assertTrue(attacker.reentryReverted(), "reentrant withdraw reverted");
        assertEq(
            bytes4(attacker.lastRevertData()),
            ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector,
            "guard fired"
        );

        // Exactly one payout, and the victim's escrow is untouched.
        assertEq(address(attacker).balance, attackerBefore + AMOUNT, "paid exactly once");
        assertEq(address(escrow).balance, AMOUNT, "victim funds intact");
        assertEq(escrow.pendingWithdrawals(address(attacker)), 0, "attacker balance zeroed");
        assertTrue(escrow.getState(victimEscrow) == EscrowUpgradeable.State.Funded, "victim state");
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_GetEscrow_RevertsForUnknownEscrow() public {
        vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.EscrowDoesNotExist.selector, 99));
        escrow.getEscrow(99);
    }

    function test_GetState_ReturnsNoneForUnknownEscrow() public view {
        assertTrue(escrow.getState(99) == EscrowUpgradeable.State.None, "None");
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Fund_RejectsAnyWrongAmount(uint256 sent) public {
        sent = bound(sent, 0, 50 ether);
        vm.assume(sent != AMOUNT);

        uint256 escrowId = _create();
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(EscrowUpgradeable.IncorrectAmount.selector, AMOUNT, sent)
        );
        escrow.fund{value: sent}(escrowId);
    }

    function testFuzz_CreateEscrow_RejectsNonParties(address caller) public {
        vm.assume(caller != address(0) && caller != seller && caller != arbiter);
        vm.assume(caller.code.length == 0);

        vm.prank(caller);
        uint256 escrowId = escrow.createEscrow(seller, arbiter, AMOUNT, COMMITMENT);

        EscrowUpgradeable.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.buyer, caller, "caller is buyer");
    }

    function testFuzz_ResolveDispute_OnlyEverPaysBuyerOrSeller(uint8 rulingRaw, address caller)
        public
    {
        uint256 escrowId = _createFundAndDispute();

        EscrowUpgradeable.Ruling ruling = EscrowUpgradeable.Ruling(bound(rulingRaw, 0, 1));

        if (caller != arbiter) {
            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(EscrowUpgradeable.NotAuthorized.selector, caller));
            escrow.resolveDispute(escrowId, ruling, "rationale");
            return;
        }

        vm.prank(arbiter);
        escrow.resolveDispute(escrowId, ruling, "rationale");

        uint256 toBuyer = escrow.pendingWithdrawals(buyer);
        uint256 toSeller = escrow.pendingWithdrawals(seller);
        assertEq(toBuyer + toSeller, AMOUNT, "all funds went to a party");
        assertEq(escrow.pendingWithdrawals(arbiter), 0, "arbiter never paid");
    }
}
