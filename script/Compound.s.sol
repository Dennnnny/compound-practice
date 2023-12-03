// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import {Script} from "forge-std/Script.sol";

import "compound-protocol/contracts/CErc20.sol";
import "compound-protocol/contracts/Comptroller.sol";
import "compound-protocol/contracts/WhitePaperInterestRateModel.sol";
import "compound-protocol/contracts/CErc20Delegator.sol";
import "compound-protocol/contracts/Unitroller.sol";
import "compound-protocol/contracts/SimplePriceOracle.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Compound is Script {}
