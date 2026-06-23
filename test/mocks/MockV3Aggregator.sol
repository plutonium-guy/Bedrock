// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MockV3Aggregator
 * @notice A minimal stand-in for a Chainlink AggregatorV3 price feed, used on local anvil
 *         and in tests. It lets tests *set* the price (and round metadata) so we can
 *         simulate a market crash or a stale feed deterministically.
 * @dev Implements the same view surface the DSCEngine consumes via AggregatorV3Interface:
 *      decimals(), latestRoundData(), getRoundData(). Based on the canonical Chainlink mock.
 */
contract MockV3Aggregator {
    uint256 public constant version = 0;

    uint8 public decimals;
    int256 public latestAnswer;
    uint256 public latestTimestamp;
    uint256 public latestRound;

    // roundId => recorded value, so getRoundData() can serve historical rounds.
    mapping(uint256 => int256) public getAnswer;
    mapping(uint256 => uint256) public getTimestamp;
    mapping(uint256 => uint256) private getStartedAt;

    constructor(uint8 _decimals, int256 _initialAnswer) {
        decimals = _decimals;
        updateAnswer(_initialAnswer);
    }

    /**
     * @notice Push a new price, advancing the round. Tests call this to crash the price.
     * @dev Stamps the round with the current block.timestamp; warping time past the
     *      OracleLib TIMEOUT after this makes the feed read as "stale".
     */
    function updateAnswer(int256 _answer) public {
        latestAnswer = _answer;
        latestTimestamp = block.timestamp;
        latestRound++;
        getAnswer[latestRound] = _answer;
        getTimestamp[latestRound] = block.timestamp;
        getStartedAt[latestRound] = block.timestamp;
    }

    /**
     * @notice Fully control round data — used to fabricate an inconsistent/incomplete round
     *         (e.g. answeredInRound < roundId) so the staleness guard can be exercised.
     */
    function updateRoundData(uint80 _roundId, int256 _answer, uint256 _timestamp, uint256 _startedAt) public {
        latestRound = _roundId;
        latestAnswer = _answer;
        latestTimestamp = _timestamp;
        getAnswer[latestRound] = _answer;
        getTimestamp[latestRound] = _timestamp;
        getStartedAt[latestRound] = _startedAt;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, getAnswer[_roundId], getStartedAt[_roundId], getTimestamp[_roundId], _roundId);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // Cast is safe: this is a test mock; latestRound is incremented one-by-one and never
        // approaches uint80's range in any test.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint80 round = uint80(latestRound);
        return (round, getAnswer[latestRound], getStartedAt[latestRound], getTimestamp[latestRound], round);
    }

    function description() external pure returns (string memory) {
        return "v0.8/tests/MockV3Aggregator.sol";
    }
}
