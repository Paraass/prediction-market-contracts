// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/WorldCupBettingHardened.sol";

// simple mock - just need updateReputation to not revert
contract MockReputation {
    function updateReputation(address, bool) external {}
    function getReputation(address) external pure returns (uint256) { return 500; }
    function setPredictionMarket(address) external {}
}

contract WorldCupBettingFuzzTest is Test {

    WorldCupBettingHardened public betting;
    MockReputation public rep;

    // using football fan names to keep it thematic lol
    address marcos   = makeAddr("marcos");   // brazil fan
    address priya    = makeAddr("priya");    // argentina fan
    address exploiter = makeAddr("exploiter"); // bad actor
    address oracle   = makeAddr("oracle");
    address me       = address(this);        // contract owner

    uint256 constant ONE_WEEK = 7 days;

    function setUp() public {
        rep = new MockReputation();
        betting = new WorldCupBettingHardened(address(rep));

        // give everyone some eth to play with
        vm.deal(marcos, 100 ether);
        vm.deal(priya, 100 ether);
        vm.deal(exploiter, 100 ether);
    }

    // -----------------------------------------------------------------------
    // helper - creates a basic yes/no market, returns id and resolution time
    // -----------------------------------------------------------------------
    function _openMarket() internal returns (uint256 id, uint256 closesAt) {
        closesAt = block.timestamp + ONE_WEEK;
        string[] memory opts = new string[](2);
        opts[0] = "Brazil wins";
        opts[1] = "Brazil loses";
        id = betting.createMarket(
            "Will Brazil reach the final?",
            "World Cup 2026 group stage",
            opts,
            closesAt,
            oracle,
            address(0)
        );
    }

    // -----------------------------------------------------------------------
    // bet sizing - any amount from dust to 10 eth should go through
    // -----------------------------------------------------------------------
    function testFuzz_anyBetSizeAccepted(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 10 ether);
        (uint256 id,) = _openMarket();

        vm.prank(marcos);
        uint256 betId = betting.placeBet{value: amount}(id, 0, amount, 0);

        assertTrue(betId > 0);
        assertEq(betting.getTotalPool(id), amount);
    }

    // exact slippage boundary - minShares == amount should be fine
    function testFuzz_exactSlippageBoundary(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 10 ether);
        (uint256 id,) = _openMarket();

        vm.prank(marcos);
        betting.placeBet{value: amount}(id, 0, amount, amount); // should not revert
    }

    // if you ask for more shares than you get, tx should revert
    function testFuzz_slippageTooHighReverts(uint96 amount, uint96 extra) public {
        vm.assume(amount > 0 && amount <= 10 ether);
        vm.assume(extra > 0);

        (uint256 id,) = _openMarket();
        uint256 greedyMin = uint256(amount) + uint256(extra);

        vm.prank(marcos);
        vm.expectRevert(WorldCupBettingHardened.SlippageExceeded.selector);
        betting.placeBet{value: amount}(id, 0, amount, greedyMin);
    }

    // -----------------------------------------------------------------------
    // payout should never exceed what was put in
    // -----------------------------------------------------------------------
    function testFuzz_payoutStaysWithinPool(uint96 stakeBrazil, uint96 stakeArgentina) public {
        vm.assume(stakeBrazil > 0.001 ether && stakeBrazil <= 5 ether);
        vm.assume(stakeArgentina > 0.001 ether && stakeArgentina <= 5 ether);

        (uint256 id, uint256 closesAt) = _openMarket();

        vm.prank(marcos);
        betting.placeBet{value: stakeBrazil}(id, 0, stakeBrazil, 0);

        vm.prank(priya);
        betting.placeBet{value: stakeArgentina}(id, 1, stakeArgentina, 0);

        vm.warp(closesAt + 1);
        vm.prank(oracle);
        betting.resolveMarket(id, 0); // brazil wins

        uint256 betId = betting.getUserBets(marcos)[0];
        uint256 before = marcos.balance;

        vm.prank(marcos);
        betting.claimWinnings(betId);

        uint256 received = marcos.balance - before;
        uint256 pot = uint256(stakeBrazil) + uint256(stakeArgentina);

        assertLe(received, pot, "got more than the pot??");
        assertGt(received, 0, "winner got nothing");
    }

    // -----------------------------------------------------------------------
    // claiming twice should always fail - no free money
    // -----------------------------------------------------------------------
    function testFuzz_cantClaimTwice(uint96 stake) public {
        vm.assume(stake > 0.001 ether && stake <= 5 ether);

        (uint256 id, uint256 closesAt) = _openMarket();

        vm.prank(marcos);
        betting.placeBet{value: stake}(id, 0, stake, 0);

        vm.warp(closesAt + 1);
        vm.prank(oracle);
        betting.resolveMarket(id, 0);

        uint256 betId = betting.getUserBets(marcos)[0];

        vm.prank(marcos);
        betting.claimWinnings(betId); // fine

        // second attempt - should brick
        vm.prank(marcos);
        vm.expectRevert(WorldCupBettingHardened.AlreadyClaimed.selector);
        betting.claimWinnings(betId);
    }

    // -----------------------------------------------------------------------
    // reentrancy - simulating what happens if someone tries to call back in
    // exploiter places a real bet, wins, claims, tries to claim again
    // -----------------------------------------------------------------------
    function testFuzz_reentrancyBlocked(uint96 stake) public {
        vm.assume(stake > 0.001 ether && stake <= 5 ether);

        (uint256 id, uint256 closesAt) = _openMarket();

        vm.prank(exploiter);
        betting.placeBet{value: stake}(id, 0, stake, 0);

        vm.warp(closesAt + 1);
        vm.prank(oracle);
        betting.resolveMarket(id, 0);

        uint256 betId = betting.getUserBets(exploiter)[0];

        vm.prank(exploiter);
        betting.claimWinnings(betId); // legitimate first claim

        // this is what a reentrant call would look like - should revert
        vm.prank(exploiter);
        vm.expectRevert(WorldCupBettingHardened.AlreadyClaimed.selector);
        betting.claimWinnings(betId);
    }

    // -----------------------------------------------------------------------
    // time checks
    // -----------------------------------------------------------------------

    // oracle can't resolve early no matter what
    function testFuzz_tooEarlyToResolve(uint32 timeLeft) public {
        vm.assume(timeLeft > 1);
        uint256 closesAt = block.timestamp + timeLeft;

        string[] memory opts = new string[](2);
        opts[0] = "YES";
        opts[1] = "NO";
        uint256 id = betting.createMarket("Q", "D", opts, closesAt, oracle, address(0));

        vm.warp(closesAt - 1);
        vm.prank(oracle);
        vm.expectRevert(WorldCupBettingHardened.TooEarly.selector);
        betting.resolveMarket(id, 0);
    }

    // no bets after market closes
    function testFuzz_noBetsAfterDeadline(uint32 delay) public {
        vm.assume(delay <= ONE_WEEK);
        (uint256 id, uint256 closesAt) = _openMarket();

        vm.warp(closesAt + delay);

        vm.prank(marcos);
        vm.expectRevert(WorldCupBettingHardened.MarketClosed.selector);
        betting.placeBet{value: 0.1 ether}(id, 0, 0.1 ether, 0);
    }

    // -----------------------------------------------------------------------
    // access control - random addresses should never be able to resolve
    // -----------------------------------------------------------------------
    function testFuzz_randomCantResolve(address rando) public {
        vm.assume(rando != oracle && rando != address(0));
        (uint256 id, uint256 closesAt) = _openMarket();

        vm.warp(closesAt + 1);
        vm.prank(rando);
        vm.expectRevert(WorldCupBettingHardened.OnlyArbitrator.selector);
        betting.resolveMarket(id, 0);
    }

    // -----------------------------------------------------------------------
    // fees - always exactly 2%, never more than the pool
    // -----------------------------------------------------------------------
    function testFuzz_feeIsAlways2Percent(uint96 stakeBrazil, uint96 stakeArgentina) public {
        vm.assume(stakeBrazil > 0.001 ether && stakeBrazil <= 5 ether);
        vm.assume(stakeArgentina > 0.001 ether && stakeArgentina <= 5 ether);

        (uint256 id, uint256 closesAt) = _openMarket();

        vm.prank(marcos);
        betting.placeBet{value: stakeBrazil}(id, 0, stakeBrazil, 0);
        vm.prank(priya);
        betting.placeBet{value: stakeArgentina}(id, 1, stakeArgentina, 0);

        vm.warp(closesAt + 1);
        vm.prank(oracle);
        betting.resolveMarket(id, 0);

        uint256 betId = betting.getUserBets(marcos)[0];
        vm.prank(marcos);
        betting.claimWinnings(betId);

        uint256 pot = uint256(stakeBrazil) + uint256(stakeArgentina);
        uint256 fees = betting.getAvailableFees(address(0));

        assertLe(fees, pot);
        assertEq(fees, (pot * 200) / 10_000, "fee should be exactly 2%");
    }

    // -----------------------------------------------------------------------
    // invariant: after a claim, contract balance == remaining fees only
    // -----------------------------------------------------------------------
    function testFuzz_balanceEqualsFeesAfterClaim(uint96 stakeHome, uint96 stakeAway) public {
        vm.assume(stakeHome > 0.001 ether && stakeHome <= 3 ether);
        vm.assume(stakeAway > 0.001 ether && stakeAway <= 3 ether);

        (uint256 id, uint256 closesAt) = _openMarket();

        vm.prank(marcos);
        betting.placeBet{value: stakeHome}(id, 0, stakeHome, 0);
        vm.prank(priya);
        betting.placeBet{value: stakeAway}(id, 1, stakeAway, 0);

        assertEq(address(betting).balance, uint256(stakeHome) + uint256(stakeAway));

        vm.warp(closesAt + 1);
        vm.prank(oracle);
        betting.resolveMarket(id, 0);

        uint256 betId = betting.getUserBets(marcos)[0];
        vm.prank(marcos);
        betting.claimWinnings(betId);

        // only fees should remain in contract
        uint256 fees = betting.getAvailableFees(address(0));
        assertEq(address(betting).balance, fees);
    }
}
