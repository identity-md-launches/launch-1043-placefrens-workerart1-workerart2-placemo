// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev For the tests: puts bytes on chain as a contract's code (a STOP byte, then the bytes), the way the frens read
///      their price table. Same name and call as the art kit's writer, so the tests read as they did.
contract FrenArt {
    function write(bytes[] calldata data) external returns (address[] memory out) {
        out = new address[](data.length);
        for (uint256 i; i < data.length; ++i) {
            bytes memory runtime = abi.encodePacked(hex"00", data[i]);
            // PUSH4 len, DUP1, PUSH1 14, PUSH1 0, CODECOPY, PUSH1 0, RETURN: the 14 bytes before the runtime
            bytes memory init = abi.encodePacked(hex"63", uint32(runtime.length), hex"80600e6000396000f3", runtime);
            address p;
            assembly ("memory-safe") {
                p := create(0, add(init, 32), mload(init))
            }
            require(p != address(0), "write");
            out[i] = p;
        }
    }
}
