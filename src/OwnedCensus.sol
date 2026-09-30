// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

import {OnchainCensus} from "./OnchainCensus.sol";

/// @notice Census whose owner adds members directly.
contract OwnedCensus is OnchainCensus {
    error LengthMismatch();

    function addMember(address user, uint88 weight) external onlyOwner {
        _addToCensus(user, weight);
    }

    /// @dev All or nothing: one rejected entry reverts the whole call.
    function addMembers(address[] calldata users, uint88[] calldata weights) external onlyOwner {
        if (users.length != weights.length) revert LengthMismatch();
        for (uint256 i = 0; i < users.length; i++) {
            _addToCensus(users[i], weights[i]);
        }
    }
}
