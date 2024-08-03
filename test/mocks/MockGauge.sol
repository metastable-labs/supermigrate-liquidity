// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./MockERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";

contract MockGauge is Context {
    IERC20 public stakingToken;
    IERC20 public rewardToken;
    address public voter;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    mapping(address => uint256) public rewards;
    bool public isAlive = true;

    constructor(IERC20 _stakingToken, IERC20 _rewardToken, address _voter) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        voter = _voter;
    }

    function setAlive(bool _isAlive) external {
        isAlive = _isAlive;
    }

    function deposit(uint256 _amount) external {
        _depositFor(_amount, msg.sender);
    }

    function deposit(uint256 _amount, address _recipient) external {
        _depositFor(_amount, _recipient);
    }

    function _depositFor(uint256 _amount, address _recipient) internal {
        require(_amount > 0, "ZeroAmount");
        require(isAlive, "NotAlive");

        stakingToken.transferFrom(tx.origin, address(this), _amount);
        totalSupply += _amount;
        balanceOf[_recipient] += _amount;
    }

    function withdraw(uint256 _amount) external {
        require(balanceOf[tx.origin] >= _amount, "Insufficient balance");
        totalSupply -= _amount;
        balanceOf[tx.origin] -= _amount;
        stakingToken.transfer(tx.origin, _amount);
    }

    function getReward(address _account) external {
        uint256 reward = rewards[_account];
        if (reward > 0) {
            rewards[_account] = 0;
            rewardToken.transfer(_account, reward);
        }
    }

    function setReward(address _account, uint256 _amount) external {
        rewards[_account] = _amount;
    }
}
