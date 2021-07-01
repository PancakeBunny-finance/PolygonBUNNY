// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface ILockedStrategy {
    function withdrawablePrincipalOf(address account) external view returns (uint);
}