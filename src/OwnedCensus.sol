// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

import {OnchainCensus} from "./OnchainCensus.sol";

/// @notice Census whose owner registers members directly. Used by tests and the e2e.
contract OwnedCensus is OnchainCensus {
    error LengthMismatch();

    function addMember(address user, uint88 weight) external onlyOwner {
        _addToCensus(user, weight);
    }

    function addMembers(address[] calldata users, uint88[] calldata weights) external onlyOwner {
        if (users.length != weights.length) revert LengthMismatch();
        for (uint256 i = 0; i < users.length; i++) {
            _addToCensus(users[i], weights[i]);
        }
    }
}
