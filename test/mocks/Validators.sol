// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { ITransferValidator721 } from "seadrop/interfaces/ITransferValidator.sol";

/// @notice Refuses every transfer. Proves the token's hook reaches the validator.
contract RefusingValidator is ITransferValidator721 {
    error Refused(address caller, address from, address to, uint256 tokenId);

    function validateTransfer(address caller, address from, address to, uint256 tokenId) external pure {
        revert Refused(caller, from, to, tokenId);
    }
}

/// @notice Allows every transfer except those made by a denied caller, the way a real
///         validator's operator allowlist refuses a royalty-stripping marketplace. The
///         interface is a view, so nothing is recorded; the revert carries the arguments.
contract DenylistValidator is ITransferValidator721 {
    mapping(address => bool) public denied;

    error OperatorDenied(address caller, address from, address to, uint256 tokenId);

    function deny(address caller, bool isDenied) external {
        denied[caller] = isDenied;
    }

    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view {
        if (denied[caller]) revert OperatorDenied(caller, from, to, tokenId);
    }
}
