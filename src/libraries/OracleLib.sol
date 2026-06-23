// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author my_coin
 * @notice Wraps Chainlink price-feed reads with a freshness check so the protocol never
 *         acts on a stale or malformed price.
 *
 * @dev Why this matters: Chainlink feeds update on a "heartbeat". If the off-chain network
 *      stalls (or a feed is deprecated), `latestRoundData` can keep returning an old answer.
 *      Pricing collateral off a stale number could let users mint against a price that no
 *      longer holds, or block fair liquidations. We treat any of the following as unusable
 *      and REVERT rather than guess:
 *        - the round was never updated (`updatedAt == 0`);
 *        - the answer comes from an earlier round than its id (`answeredInRound < roundId`);
 *        - the answer is older than TIMEOUT.
 *
 *      Design choice: we *freeze* the protocol (revert) on a stale feed. That is the
 *      conservative behaviour for a learning artifact — it is "fail closed". A production
 *      system would also weigh that a freeze blocks liquidations during exactly the volatile
 *      moments you need them; see README "Next steps".
 */
library OracleLib {
    error OracleLib__StalePrice();

    /// @notice Max age of a price before we consider it stale. Chainlink ETH/USD heartbeat
    ///         is ~1h on mainnet; 3h gives generous slack while still catching real stalls.
    uint256 private constant TIMEOUT = 3 hours;

    /**
     * @notice Drop-in replacement for `priceFeed.latestRoundData()` that reverts on stale data.
     * @return The same 5-tuple Chainlink returns, once it has passed the freshness checks.
     */
    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        // Incomplete round, or an answer carried over from a stale earlier round.
        if (updatedAt == 0 || answeredInRound < roundId) {
            revert OracleLib__StalePrice();
        }
        // Heartbeat exceeded.
        uint256 secondsSinceUpdate = block.timestamp - updatedAt;
        if (secondsSinceUpdate > TIMEOUT) {
            revert OracleLib__StalePrice();
        }

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function getTimeout() external pure returns (uint256) {
        return TIMEOUT;
    }
}
