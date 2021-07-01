// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IPresale {
    function totalBalance() view external returns (uint);
    function flipToken() view external returns (address);
}