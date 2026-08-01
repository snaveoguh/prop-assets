// SPDX-License-Identifier: GPL-3.0

/// @title JokerFix — repair NounV2 head #253 (and deal a second joker)
///
/// NounV2 proposal #1 shipped the joker head as raw deflated RLE instead of the
/// DEFLATE of `abi.encode(bytes[])`. `NounsArt.imageByIndex` cannot decode it, so
/// `heads(253)` and any `tokenURI` for a Noun rolling that head REVERT.
///
/// The JOKER 2 proposal uses this contract to resubmit the head art PAGE BY
/// PAGE: pages 0-5 byte-identical to what is on chain today, and a rebuilt
/// final page holding two correctly-encoded jokers — #253 fixed, #254 new.
/// A deck carries two.
///
/// Why page-by-page and not one big page: `imageByIndex` inflates the whole
/// page containing the requested index on every read. One 255-image page
/// costs ~90M gas per read (over the block limit and most providers'
/// eth_call caps). Preserving today's page boundaries keeps every existing
/// head read at exactly its current cost; the new joker page is 256 bytes.
///
/// `updateHeads` lives on NounsArt behind `onlyDescriptor`, and the deployed V2
/// descriptor (unlike main Nouns') exposes no `update*` passthrough. So this
/// contract is briefly made the art's descriptor, replaces the head data, checks
/// the stored count, and hands the role straight back — all inside one
/// transaction. If any check fails the whole thing reverts and nothing changes.
///
/// It holds no funds, owns nothing, and is inert once used.

pragma solidity ^0.8.19;

interface INounsArtLike {
    function updateHeads(bytes calldata encodedCompressed, uint80 decompressedLength, uint16 imageCount) external;
    function addHeads(bytes calldata encodedCompressed, uint80 decompressedLength, uint16 imageCount) external;
    function setDescriptor(address descriptor) external;
    function headCount() external view returns (uint256);
    function descriptor() external view returns (address);
}

contract JokerFix {
    /// NounV2 art contract.
    INounsArtLike public constant ART = INounsArtLike(0x3409A4A360A028b7Aa2eBF769d6306d96B976b3f);
    /// The real NounV2 descriptor — the role is returned here before we finish.
    address public constant DESCRIPTOR = 0xAe0247Ca34B211a61b03A95F8008DCb8B3124B89;

    error NotDescriptor();
    error NoPages();
    error LengthMismatch();
    error CountMismatch(uint256 got, uint256 want);
    error DescriptorNotRestored();

    event Fixed(uint256 headCount, uint256 pages);

    /// @notice Replace all head art page-by-page, verify the count, and hand
    ///         the descriptor role back.
    /// @dev Callable by anyone, but only *works* while this contract holds the
    ///      art's descriptor role — which only the DAO can grant, and which this
    ///      function gives up before returning. After a successful run it can
    ///      never do anything again.
    ///
    ///      The first page goes through `updateHeads` (replaceTraitData: wipes
    ///      all existing pages and resets the count), each further page through
    ///      `addHeads`. We deliberately do NOT read `heads()` back in here —
    ///      decoding the big page costs ~83M gas, far over the block limit.
    ///      Readability is verified off-chain via `eth_call heads(i)` right
    ///      after execution, which exercises the identical decode path for free.
    /// @param encodedCompressed per page: raw-DEFLATE of abi.encode(bytes[] images)
    /// @param decompressedLengths per page: length of the ABI-ENCODED buffer
    /// @param imageCounts per page: number of images in the array
    function fix(
        bytes[] calldata encodedCompressed,
        uint80[] calldata decompressedLengths,
        uint16[] calldata imageCounts
    ) external {
        if (ART.descriptor() != address(this)) revert NotDescriptor();
        uint256 n = encodedCompressed.length;
        if (n == 0) revert NoPages();
        if (decompressedLengths.length != n || imageCounts.length != n) revert LengthMismatch();

        uint256 want = 0;
        for (uint256 i = 0; i < n; i++) {
            if (i == 0) {
                ART.updateHeads(encodedCompressed[0], decompressedLengths[0], imageCounts[0]);
            } else {
                ART.addHeads(encodedCompressed[i], decompressedLengths[i], imageCounts[i]);
            }
            want += imageCounts[i];
        }

        uint256 count = ART.headCount();
        if (count != want) revert CountMismatch(count, want);

        ART.setDescriptor(DESCRIPTOR);
        if (ART.descriptor() != DESCRIPTOR) revert DescriptorNotRestored();

        emit Fixed(count, n);
    }

    /// @notice Escape hatch: return the descriptor role without touching the art.
    /// @dev Only useful if `fix` is never called; leaves state untouched.
    function abort() external {
        if (ART.descriptor() != address(this)) revert NotDescriptor();
        ART.setDescriptor(DESCRIPTOR);
    }
}
