// SPDX-License-Identifier: GNU
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IWETH is IERC20 {
    function deposit() external payable;

    function withdraw(uint256) external;
}

contract MockWETH is ERC20, IWETH {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable override {
        require(msg.value > 0, "No ETH sent");
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external override {
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
}
