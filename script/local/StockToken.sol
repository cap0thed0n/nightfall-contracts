// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { ERC20 } from "solmate/tokens/ERC20.sol";

/// @notice A stand-in for a testnet stock token on a local chain: a plain 18-decimal ERC-20 the
///         deployer mints. Local only; never deployed to a real chain.
contract StockToken is ERC20 {
    address internal immutable minter;

    constructor(string memory symbol_) ERC20(symbol_, symbol_, 18) {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "only the deployer mints");
        _mint(to, amount);
    }
}
