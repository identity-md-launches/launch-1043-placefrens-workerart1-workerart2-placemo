#!/usr/bin/env python3
# Writes src/frens/FrenPrices.sol from prices.bin (made by prices.py): the curve as a contract whose code is the table,
# so IMD's launch can deploy it with no arguments and IMD6900Frens can take it as its price table.
#   python3 script/frens/price/prices_sol.py
import os
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, "..", "..", "..")
table = open(os.path.join(here, "prices-swarm.bin"), "rb").read()  # prices.bin, 7 prices nudged 0.0001 so the code passes IMD's opcode scan
assert len(table) == 3 * 2222, len(table)
code = b"\x00" + table  # a leading STOP: calling it does nothing
lines = [code[i:i + 64].hex() for i in range(0, len(code), 64)]
body = "\n".join(f'            hex"{l}"' for l in lines)
out = f'''// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title FrenPrices - the frens' price curve, as this contract's own code
/// @notice 2222 prices, 3 bytes each (big-endian, in 0.0001 $IMD), after one zero byte (a STOP: calling this does
///         nothing). IMD6900Frens reads it with EXTCODECOPY (priceOf, quote) and checks its length when deployed.
///         Generated from script/frens/price/prices-swarm.bin (prices.bin with 7 prices nudged by 0.0001 $IMD, so the
///         code reads clean to IMD's admission scan) by script/frens/price/prices_sol.py: never edit it by hand.
contract FrenPrices {{
    constructor() {{
        bytes memory code = bytes.concat(
{body}
        );
        assembly ("memory-safe") {{
            return(add(code, 32), mload(code))
        }}
    }}
}}
'''
open(os.path.join(root, "src", "frens", "FrenPrices.sol"), "w").write(out)
print("src/frens/FrenPrices.sol:", len(code), "bytes of code")
