// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockStandardBridge {
    mapping(address => uint256) public bridgedAmounts;
    mapping(address => address) public localToRemoteToken;
    mapping(address => uint256) public expectedAmounts;

    function setExpectedCalls(
        address localTokenA,
        address remoteTokenA,
        uint256 amountA,
        address localTokenB,
        address remoteTokenB,
        uint256 amountB
    ) external {
        localToRemoteToken[localTokenA] = remoteTokenA;
        localToRemoteToken[localTokenB] = remoteTokenB;
        expectedAmounts[localTokenA] = amountA;
        expectedAmounts[localTokenB] = amountB;
    }

    function bridgeERC20To(
        address localToken,
        address remoteToken,
        address to,
        uint256 amount,
        uint32 minGasLimit,
        bytes memory extraData
    ) external {
        require(localToRemoteToken[localToken] == remoteToken, "Unexpected remote token");
        require(amount == expectedAmounts[localToken], "Unexpected amount");
        bridgedAmounts[localToken] += amount;
    }

    function bridgeETHTo(address to, uint32 minGasLimit, bytes memory extraData) external payable {
        bridgedAmounts[address(0)] += msg.value;
    }

    function getBridgedAmount(address token) external view returns (uint256) {
        return bridgedAmounts[token];
    }
}
