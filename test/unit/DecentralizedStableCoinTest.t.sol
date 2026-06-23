// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoinTest
 * @notice Unit tests for the DSC token in isolation (the engine is not involved here).
 *         The test contract itself is the owner, so it can call mint/burn directly.
 */
contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin dsc;

    address constant ALICE = address(0xA11CE);

    function setUp() public {
        dsc = new DecentralizedStableCoin(); // owner == this test contract
    }

    /*//////////////////////////////////////////////////////////////
                               METADATA
    //////////////////////////////////////////////////////////////*/

    function test_NameAndSymbol() public view {
        assertEq(dsc.name(), "Decentralized Stable Coin");
        assertEq(dsc.symbol(), "DSC");
    }

    function test_OwnerIsDeployer() public view {
        assertEq(dsc.owner(), address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                 MINT
    //////////////////////////////////////////////////////////////*/

    function test_OwnerCanMint() public {
        bool ok = dsc.mint(ALICE, 100 ether);
        assertTrue(ok);
        assertEq(dsc.balanceOf(ALICE), 100 ether);
        assertEq(dsc.totalSupply(), 100 ether);
    }

    function test_MintRevertsOnZeroAddress() public {
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__NotZeroAddress.selector);
        dsc.mint(address(0), 100 ether);
    }

    function test_MintRevertsOnZeroAmount() public {
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.mint(ALICE, 0);
    }

    function test_MintRevertsIfNotOwner() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        dsc.mint(ALICE, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                 BURN
    //////////////////////////////////////////////////////////////*/

    function test_OwnerCanBurn() public {
        // Mint to the owner (this contract), then burn from its own balance.
        dsc.mint(address(this), 100 ether);
        dsc.burn(40 ether);
        assertEq(dsc.balanceOf(address(this)), 60 ether);
        assertEq(dsc.totalSupply(), 60 ether);
    }

    function test_BurnRevertsOnZeroAmount() public {
        dsc.mint(address(this), 100 ether);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.burn(0);
    }

    function test_BurnRevertsWhenAmountExceedsBalance() public {
        dsc.mint(address(this), 100 ether);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        dsc.burn(101 ether);
    }

    function test_BurnRevertsIfNotOwner() public {
        dsc.mint(ALICE, 100 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        dsc.burn(10 ether);
    }
}
