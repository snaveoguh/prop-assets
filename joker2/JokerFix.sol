// SPDX-License-Identifier: GPL-3.0

/// @title JokerFix — repair NounV2 head #253 (and deal a second joker)
///
/// NounV2 proposal #1 shipped the joker head as raw deflated RLE instead of the
/// DEFLATE of `abi.encode(bytes[])`. `NounsArt.imageByIndex` cannot decode it, so
/// `heads(253)` and any `tokenURI` for a Noun rolling that head REVERT.
///
/// The JOKER 2 proposal uses this contract to rebuild the head trait PAGE BY
/// PAGE: pages 0-5 are re-attached via their EXISTING on-chain SSTORE2
/// pointers — byte-identical art, no re-upload — and the broken final page is
/// replaced by a 256-byte page holding two correctly-encoded jokers: #253
/// fixed, #254 new. A deck carries two.
///
/// Why pointers and not calldata: EIP-7825 caps any transaction at 2^24 gas
/// (~16.78M), and a proposal carrying the 22KB art payload costs ~18.3M just
/// to store in the governor — unminable. Every page except the new joker page
/// already lives on chain, so this contract references those pointers and
/// carries only the 39-byte joker page inline. The whole proposal fits in a
/// few hundred bytes of calldata.
///
/// Why page-by-page and not one big page: `imageByIndex` inflates the whole
/// page containing the requested index on every read. One 255-image page
/// costs ~90M gas per read. Preserving today's page boundaries keeps every
/// existing head read at exactly its current cost.
///
/// `updateHeads*` lives on NounsArt behind `onlyDescriptor`, and the deployed
/// V2 descriptor (unlike main Nouns') exposes no `update*` passthrough. So this
/// contract is briefly made the art's descriptor, rebuilds the head trait,
/// checks the stored count, and hands the role straight back — all inside one
/// transaction. If any check fails the whole thing reverts and nothing changes.
///
/// It holds no funds, owns nothing, and is inert once used.

pragma solidity ^0.8.19;

interface INounsArtLike {
    function updateHeadsFromPointer(address pointer, uint80 decompressedLength, uint16 imageCount) external;
    function addHeadsFromPointer(address pointer, uint80 decompressedLength, uint16 imageCount) external;
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

    // Existing head-art pages, reused byte-identical via their live SSTORE2
    // pointers. Values read from ART.getHeadsTrait() on 2026-08-01.
    address internal constant PAGE0 = 0x457852249b25075A6966859227DF58d4483c43F5; // 234 imgs, 60352 B
    address internal constant PAGE1 = 0x880799829d13b87bDeDAaDB7eEAE43a780319295; //   8 imgs,  1952 B
    address internal constant PAGE2 = 0x4074B6fe88754B7Ec7386c8B14b3C74909e97502; //   8 imgs,  2112 B
    address internal constant PAGE3 = 0xa168684FE3DB74AbD5AFbEe5bf87eB8b0c92aC3e; //   1 img,    320 B
    address internal constant PAGE4 = 0xEe668A8dd23d9cc68f312cCb1F57b702D8b46CC0; //   1 img,    288 B
    address internal constant PAGE5 = 0x121e7b5715895e9A23A3da9A078E0571BFC8023D; //   1 img,    224 B

    /// raw-DEFLATE of abi.encode([joker, joker]) — the index card rotated 180°,
    /// twice. Inflates to 256 bytes.
    bytes internal constant JOKER_PAGE =
        hex"6360c00b14f04b33301190772020df40405e9c815d5a84558747ac17095beaf030100908ea0700";

    uint256 internal constant EXPECTED_HEAD_COUNT = 255;

    error NotDescriptor();
    error CountMismatch(uint256 got, uint256 want);
    error DescriptorNotRestored();

    event Fixed(uint256 headCount);

    /// @notice Rebuild the head trait, verify the count, and hand the
    ///         descriptor role back.
    /// @dev Callable by anyone, but only *works* while this contract holds the
    ///      art's descriptor role — which only the DAO can grant, and which this
    ///      function gives up before returning. After a successful run it can
    ///      never do anything again.
    ///
    ///      We deliberately do NOT read `heads()` back in here — decoding the
    ///      big page costs ~85M gas, far over the per-tx limit. Readability is
    ///      verified off-chain via `eth_call heads(i)` right after execution,
    ///      which exercises the identical decode path for free.
    function fix() external {
        if (ART.descriptor() != address(this)) revert NotDescriptor();

        // First call wipes the old page list (including the broken raw-RLE
        // page) and starts fresh; the rest append.
        ART.updateHeadsFromPointer(PAGE0, 60352, 234);
        ART.addHeadsFromPointer(PAGE1, 1952, 8);
        ART.addHeadsFromPointer(PAGE2, 2112, 8);
        ART.addHeadsFromPointer(PAGE3, 320, 1);
        ART.addHeadsFromPointer(PAGE4, 288, 1);
        ART.addHeadsFromPointer(PAGE5, 224, 1);
        ART.addHeads(JOKER_PAGE, 256, 2);

        uint256 count = ART.headCount();
        if (count != EXPECTED_HEAD_COUNT) revert CountMismatch(count, EXPECTED_HEAD_COUNT);

        ART.setDescriptor(DESCRIPTOR);
        if (ART.descriptor() != DESCRIPTOR) revert DescriptorNotRestored();

        emit Fixed(count);
    }

    /// @notice Escape hatch: return the descriptor role without touching the art.
    /// @dev Only useful if `fix` is never called; leaves state untouched.
    function abort() external {
        if (ART.descriptor() != address(this)) revert NotDescriptor();
        ART.setDescriptor(DESCRIPTOR);
    }
}
