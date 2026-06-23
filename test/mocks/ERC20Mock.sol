// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ERC20Mock
 * @notice A freely mintable/burnable ERC20 used to stand in for real collateral
 *         (wETH, wBTC) in tests and on local anvil. Anyone can mint — that is fine
 *         because this only ever exists on test networks, never mainnet.
 */
contract ERC20Mock is ERC20 {
    constructor(string memory name, string memory symbol, address initialAccount, uint256 initialBalance)
        ERC20(name, symbol)
    {
        // Optionally pre-fund an account at construction time.
        if (initialBalance > 0) {
            _mint(initialAccount, initialBalance);
        }
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}
