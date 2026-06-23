// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin (DSC)
 * @author my_coin
 * @notice The ERC20 token that represents the stablecoin itself.
 *
 * Properties:
 *  - Collateral:  Exogenous (wETH, wBTC) — the backing assets live outside this token.
 *  - Minting:     Algorithmic — supply is governed entirely by the DSCEngine.
 *  - Peg:         Soft-pegged to USD ($1).
 *
 * @dev This contract is deliberately "dumb": it holds no business logic. It is just a
 *      mint/burn-controlled ERC20. ALL of the interesting rules (overcollateralization,
 *      health factor, liquidation) live in {DSCEngine}. The engine is set as the `owner`
 *      of this contract, so only the engine can create or destroy DSC. Keeping the token
 *      logic-free shrinks its attack surface and makes the system easier to reason about.
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    /// @notice Thrown when a mint/burn amount is zero (a no-op that almost always signals a bug).
    error DecentralizedStableCoin__MustBeMoreThanZero();
    /// @notice Thrown when trying to burn more than the contract's own balance.
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    /// @notice Thrown when minting to the zero address (tokens would be unrecoverable).
    error DecentralizedStableCoin__NotZeroAddress();

    /**
     * @dev The deployer becomes the initial owner. The deploy script immediately transfers
     *      ownership to the DSCEngine via {Ownable-transferOwnership}, so in practice the
     *      engine is the only address that can ever mint or burn.
     */
    constructor() ERC20("Decentralized Stable Coin", "DSC") Ownable(msg.sender) {}

    /**
     * @notice Destroy `_amount` DSC held by this contract (used by the engine when a user
     *         repays/burns debt; the engine first pulls the user's DSC into itself).
     * @dev Overrides {ERC20Burnable-burn} to add owner-gating and explicit input checks.
     *      We re-check the balance ourselves to emit a domain-specific error rather than the
     *      generic ERC20 underflow revert.
     */
    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount == 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount); // performs the actual _burn after our checks
    }

    /**
     * @notice Create `_amount` new DSC and credit it to `_to`.
     * @return Always true on success (mirrors common mintable-token conventions so callers
     *         can `require` on the return value if they wish).
     */
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        if (_amount == 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
