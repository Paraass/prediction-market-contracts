// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IReputationSystem {
    function updateReputation(address user, bool correct) external;
    function getReputation(address user) external view returns (uint256);
}

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract WorldCupBetting is ReentrancyGuard, Ownable {
    enum MarketStatus {
        Open,      // 0
        Closed,    // 1
        Resolved,  // 2
        Cancelled  // 3
    }

    struct Market {
        uint256 id;
        string question;
        string description;
        string[] outcomes;
        uint256 resolutionTime;
        address arbitrator;
        address tokenAddress;
        MarketStatus status;
        uint256 winningOutcome;
        address creator;
        // outcome index => total shares bet on that outcome
        mapping(uint256 => uint256) outcomePools;
        uint256 totalPool;
    }

    struct MarketView {
        uint256 id;
        string question;
        string description;
        string[] outcomes;
        uint256 resolutionTime;
        address arbitrator;
        address tokenAddress;
        MarketStatus status;
        uint256 winningOutcome;
        address creator;
    }

    struct Bet {
        uint256 id;
        uint256 marketId;
        address owner;
        uint256 outcomeIndex;
        uint256 shares;       // == amount deposited (1:1)
        uint256 amount;       // original deposit
        bool claimed;
        // secondary market
        bool listed;
        uint256 listPrice;
    }

    IReputationSystem public reputationSystem;
    uint256 public marketCount;
    uint256 public betCount;

    mapping(uint256 => Market) private markets;
    mapping(uint256 => Bet) private bets;

    // user => betIds[]
    mapping(address => uint256[]) private userBets;
    // marketId => betIds[]
    mapping(uint256 => uint256[]) private marketBets;

    // token => accumulated fees
    mapping(address => uint256) private availableFees;

    uint256 private constant FEE_BPS = 200; // 2%
    uint256 private constant BPS_DENOM = 10_000;

    constructor(address _reputationSystem) Ownable(msg.sender) {
        reputationSystem = IReputationSystem(_reputationSystem);
    }

    // ─────────────────────────────────────────────
    // CORE LIFECYCLE
    // ─────────────────────────────────────────────

    function createMarket(
        string memory _question,
        string memory _description,
        string[] memory _outcomes,
        uint256 _resolutionTime,
        address _arbitrator,
        address _tokenAddress
    ) external returns (uint256) {
        require(_outcomes.length >= 2, "Need at least 2 outcomes");
        require(_resolutionTime > block.timestamp, "Resolution in past");

        marketCount++;
        Market storage m = markets[marketCount];
        m.id = marketCount;
        m.question = _question;
        m.description = _description;
        m.outcomes = _outcomes;
        m.resolutionTime = _resolutionTime;
        m.arbitrator = _arbitrator;
        m.tokenAddress = _tokenAddress;
        m.status = MarketStatus.Open;
        m.creator = msg.sender;

        return marketCount;
    }

    function placeBet(
        uint256 _marketId,
        uint256 _outcomeIndex,
        uint256 _amount,
        uint256 _minShares
    ) external payable returns (uint256) {
        Market storage m = markets[_marketId];
        require(m.status == MarketStatus.Open, "Market closed");
        require(block.timestamp < m.resolutionTime, "Market closed");
        require(_outcomeIndex < m.outcomes.length, "Invalid outcome");

        // Pull funds
        if (m.tokenAddress == address(0)) {
            require(msg.value == _amount, "ETH mismatch");
        } else {
            require(msg.value == 0, "No ETH for ERC20 market");
            IERC20(m.tokenAddress).transferFrom(msg.sender, address(this), _amount);
        }

        // Shares = amount (1:1 simple model; satisfies slippage logic)
        uint256 shares = _amount;
        require(shares >= _minShares, "Slippage exceeded");

        m.outcomePools[_outcomeIndex] += shares;
        m.totalPool += _amount;

        betCount++;
        Bet storage b = bets[betCount];
        b.id = betCount;
        b.marketId = _marketId;
        b.owner = msg.sender;
        b.outcomeIndex = _outcomeIndex;
        b.shares = shares;
        b.amount = _amount;
        b.claimed = false;
        b.listed = false;

        userBets[msg.sender].push(betCount);
        marketBets[_marketId].push(betCount);

        return betCount;
    }

    function resolveMarket(uint256 _marketId, uint256 _winningOutcome) external {
        Market storage m = markets[_marketId];
        require(block.timestamp >= m.resolutionTime, "Too early");
        require(msg.sender == m.arbitrator, "Only arbitrator");
        require(m.status == MarketStatus.Open, "Already resolved");
        require(_winningOutcome < m.outcomes.length, "Invalid outcome");

        m.status = MarketStatus.Resolved;
        m.winningOutcome = _winningOutcome;
    }

    function claimWinnings(uint256 _betId) external nonReentrant {
        Bet storage b = bets[_betId];
        require(b.owner == msg.sender, "Not your bet");
        require(!b.claimed, "Already claimed");

        Market storage m = markets[b.marketId];
        require(m.status == MarketStatus.Resolved, "Not resolved");

        b.claimed = true;

        bool isWinner = (b.outcomeIndex == m.winningOutcome);

        // Update reputation for both winners and losers
        try reputationSystem.updateReputation(msg.sender, isWinner) {} catch {}

        if (!isWinner) {
            // Loser gets nothing, just reputation update
            return;
        }

        // Payout: proportional share of total pool
        uint256 winnerPool = m.outcomePools[m.winningOutcome];
        require(winnerPool > 0, "No winner pool");

        // userPayout = (userShares / totalWinnerShares) * totalPool
        uint256 grossPayout = (b.shares * m.totalPool) / winnerPool;

        // 2% platform fee
        uint256 fee = (grossPayout * FEE_BPS) / BPS_DENOM;
        uint256 netPayout = grossPayout - fee;

        availableFees[m.tokenAddress] += fee;

        _transferOut(m.tokenAddress, msg.sender, netPayout);
    }

    // ─────────────────────────────────────────────
    // SECONDARY MARKET
    // ─────────────────────────────────────────────

    function listPosition(uint256 _betId, uint256 _price) external {
        Bet storage b = bets[_betId];
        require(b.owner == msg.sender, "Not your bet");
        require(!b.claimed, "Already claimed");
        require(!b.listed, "Already listed");

        b.listed = true;
        b.listPrice = _price;
    }

    function cancelListing(uint256 _betId) external {
        Bet storage b = bets[_betId];
        require(b.owner == msg.sender, "Not your bet");
        require(b.listed, "Not listed");

        b.listed = false;
        b.listPrice = 0;
    }

    function buyPosition(uint256 _betId) external payable nonReentrant {
        Bet storage b = bets[_betId];
        require(b.listed, "Not listed");
        require(msg.value == b.listPrice, "Wrong price");
        require(msg.sender != b.owner, "Cannot buy own position");

        address seller = b.owner;
        uint256 price = b.listPrice;

        b.owner = msg.sender;
        b.listed = false;
        b.listPrice = 0;

        // Update user bet tracking
        userBets[msg.sender].push(_betId);

        // Pay seller
        (bool ok, ) = payable(seller).call{value: price}("");
        require(ok, "Transfer failed");
    }

    // ─────────────────────────────────────────────
    // FEES
    // ─────────────────────────────────────────────

    function withdrawFees(address _token) external onlyOwner nonReentrant {
        uint256 amount = availableFees[_token];
        require(amount > 0, "No fees");
        availableFees[_token] = 0;
        _transferOut(_token, owner(), amount);
    }

    function getAvailableFees(address _token) external view returns (uint256) {
        return availableFees[_token];
    }

    // ─────────────────────────────────────────────
    // VIEW / QUERY
    // ─────────────────────────────────────────────

    function getUserBets(address _user) external view returns (uint256[] memory) {
        return userBets[_user];
    }

    function getMarketBets(uint256 _marketId) external view returns (uint256[] memory) {
        return marketBets[_marketId];
    }

    function getMarket(uint256 _marketId)
        external
        view
        returns (MarketView memory)
    {
        Market storage m = markets[_marketId];
        return MarketView({
            id: m.id,
            question: m.question,
            description: m.description,
            outcomes: m.outcomes,
            resolutionTime: m.resolutionTime,
            arbitrator: m.arbitrator,
            tokenAddress: m.tokenAddress,
            status: m.status,
            winningOutcome: m.winningOutcome,
            creator: m.creator
        });
    }

    function calculateShares(
        uint256 /* _marketId */,
        uint256 /* _outcomeIndex */,
        uint256 _amount
    ) public pure returns (uint256) {
        // 1:1 share model
        return _amount;
    }

    function getPrice(
        uint256 _marketId,
        uint256 _outcomeIndex
    ) public view returns (uint256) {
        Market storage m = markets[_marketId];
        if (m.totalPool == 0) return 0;
        return (m.outcomePools[_outcomeIndex] * 1e18) / m.totalPool;
    }

    function getTotalPool(uint256 _marketId) public view returns (uint256) {
        return markets[_marketId].totalPool;
    }

    // ─────────────────────────────────────────────
    // INTERNAL
    // ─────────────────────────────────────────────

    function _transferOut(address _token, address _to, uint256 _amount) internal {
        if (_token == address(0)) {
            (bool ok, ) = payable(_to).call{value: _amount}("");
            require(ok, "ETH transfer failed");
        } else {
            IERC20(_token).transfer(_to, _amount);
        }
    }
}


