// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockEndpoint {
    address public delegate;

    function setDelegate(address _delegate) external {
        delegate = _delegate;
    }

    struct MessagingParams {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        bool payInLzToken;
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    function send(MessagingParams calldata _params, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory receipt)
    {
        // Mock implementation
        // In a real scenario, this would handle the cross-chain messaging
        // For testing, returning a dummy receipt
        return MessagingReceipt({guid: bytes32(0), nonce: 0, fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})});
    }
}
