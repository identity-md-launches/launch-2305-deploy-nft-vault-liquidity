// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Test double for vault-only tests. Actual pool bindings are exercised by InkSystem and mainnet forks.
contract ConfiguredLiquidity {
    IERC20 public immutable ink;
    bool public poolSet = true;

    constructor(IERC20 ink_) {
        ink = ink_;
    }

    function addLiquidity() external pure returns (uint256) {
        return 0;
    }
}
