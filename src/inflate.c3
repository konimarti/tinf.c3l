<*
 Ported to C3 by Koni Marti <koni.marti@gmail.com>

/*
 * tinflate - tiny inflate
 *
 * Copyright (c) 2003-2019 Joergen Ibsen
 *
 * This software is provided 'as-is', without any express or implied
 * warranty. In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 *   1. The origin of this software must not be misrepresented; you must
 *      not claim that you wrote the original software. If you use this
 *      software in a product, an acknowledgment in the product
 *      documentation would be appreciated but is not required.
 *
 *   2. Altered source versions must be plainly marked as such, and must
 *      not be misrepresented as being the original software.
 *
 *   3. This notice may not be removed or altered from any source
 *      distribution.
 */

*>
module tinf::inflate;

import tinf::error;
import std::io;

struct TinfTree
{
	ushort [16] counts;
	ushort[288] symbols;
	int max_sym;
}

struct TinfData
{
	char *source;
	char *source_end;
	uint tag;
	int bitcount;
	int overflow;

	char *dest_start;
	char *dest;
	char *dest_end;

	TinfTree ltree; // literal/length tree
	TinfTree dtree; // distance tree
}

<*
require @is_instream(stream)
*>
macro ushort? read_le_ushort(stream)
{
	char lo_byte = stream.read_byte()!; // p[0]
	char hi_byte = stream.read_byte()!; // p[1]
	return (ushort)((ushort)hi_byte << 8 | (ushort)lo_byte);
}

fn void build_fixed_trees(TinfTree *lt, TinfTree *dt)
{
	ushort i;

	lt.counts[..] = 0;

	lt.counts[7] = 24;
	lt.counts[8] = 152;
	lt.counts[9] = 112;

	for (i = 0; i < 24; i++)
	{
		lt.symbols[i] = 256 + i;
	}
	for (i = 0; i < 144; i++)
	{
		lt.symbols[24 + i] = i;
	}
	for (i = 0; i < 8; i++)
	{
		lt.symbols[24 + 144 + i] = 280 + i;
	}
	for (i = 0; i < 112; i++)
	{
		lt.symbols[24 + 144 + 8 + i] = 144 + i;
	}

	lt.max_sym = 285;

	// build fixed distance tree
	dt.counts[..] = 0;
	dt.counts[5] = 32;

	for (i = 0; i < 32; i++)
	{
		dt.symbols[i] = i;
	}

	dt.max_sym = 29;
}

fn void? build_tree(TinfTree *t, char[] lengths, uint num)
{
	ushort[16] offs;
	uint i, num_codes, available;

	assert(num <= 288);

	t.counts[..] = 0;

	t.max_sym = -1;

	for (i = 0; i < num; ++i)
	{
		assert(lengths[i] <= 15);

		if (lengths[i])
		{
			t.max_sym = i;
			t.counts[lengths[i]]++;
		}
	}

	// compute offset table for distribution sort
	available = 1;
	num_codes = 0;
	for (i = 0; i < 16; i++)
	{
		uint used = t.counts[i];

		// check lengh contains no more codes than available
		if (used > available) return error::DATA_ERROR?;
		available = 2 * (available - used);

		offs[i] = (ushort)num_codes;
		num_codes += used;
	}

	// check all codes were used, or for the special case of only one code
	// that it has length 1
	if ((num_codes > 1 && available > 0) || (num_codes == 1 && t.counts[1] != 1))
	{
		return error::DATA_ERROR?;
	}

	// fill in symbols sorted by code
	for (i = 0; i < num; i++)
	{
		if (lengths[i])
		{
			t.symbols[offs[lengths[i]]++] = (ushort)i;
		}
	}

	// for the special case of only one code (which will be 0) add a code 1
	// which results in a symbol that is too large
	if (num_codes == 1)
	{
		t.counts[1] = 2;
		t.symbols[1] = (ushort)t.max_sym + 1;
	}
}

fn void refill(TinfData *d, int num)
{
	assert(num >= 0 && num <= 32);

	// read bytes until at least num bits available
	while (d.bitcount < num)
	{
		if (d.source != d.source_end)
		{
			d.tag |= *(d.source++) << d.bitcount;
		}
		else
		{
			d.overflow = 1;
		}
		d.bitcount += 8;
	}

	assert(d.bitcount <= 32);
}

fn uint getbits_no_refill(TinfData *d, int num)
{
	uint bits;

	assert(num >=0 && num <= d.bitcount);

	// get bits from tag
	bits = d.tag & ((1UL << num) - 1);

	// remove bits from tag
	d.tag >>= num;
	d.bitcount -= num;

	return bits;
}

fn uint getbits(TinfData *d, int num)
{
	refill(d, num);
	return getbits_no_refill(d, num);
}

fn uint getbits_base(TinfData *d, int num, int base) @inline
{
	return base + (num ? getbits(d, num) : 0);
}

fn int decode_symbol(TinfData *d, TinfTree *t)
{
	int base = 0;
	int offs = 0;
	int len;

	// get more bits while code index is above number of codes
	for (len = 1; ; len++)
	{
		offs = 2 * offs + getbits(d, 1);

		assert(len <= 15);

		if (offs < t.counts[len]) break;

		base += t.counts[len];
		offs -= t.counts[len];
	}

	assert(base + offs >= 0 && base + offs < 288);

	return t.symbols[base + offs];
}

// given a data stream, decode dynamic trees from it
fn void? decode_trees(TinfData *d, TinfTree *lt, TinfTree *dt)
{
	char[288 + 32] lengths;

	// special ordering of codes length codes
	char[*] clcidx = {
		16, 17, 18, 0,  8, 7,  9, 6, 10, 5,
		11,  4, 12, 3, 13, 2, 14, 1, 15
	};

	uint hlit, hdist, hclen;
	uint i, num, length;

	// get 5 bits HLIT (257-286)
	hlit = getbits_base(d, 5, 257);

	// get 5 bits HDIST (1-32)
	hdist = getbits_base(d, 5, 1);

	// get 4 bits HCLEN (4-19)
	hclen = getbits_base(d, 4, 4);

	// rfc limits the range of HLIT to 286, but lists HDIST as range 1-32,
	// even though distance codes 30 and 31 have no meaning.
	if (hlit > 286 || hdist > 30) return error::DATA_ERROR?;

	lengths[:19] = 0;

	// read code length for code length alphabet
	for (i = 0; i < hclen; i++)
	{
		// get 3 bits code length (0-7)
		uint clen = getbits(d, 3);
		lengths[clcidx[i]] = (char)clen;
	}

	// build code length tree (in literal/length tree to save space)
	build_tree(lt, lengths[..], 19)!;

	// check code length tree is not empty
	if (lt.max_sym == -1) return error::DATA_ERROR?;

	// decode code lengths for the dynamic trees
	for (num = 0; num < hlit + hdist;)
	{
		int sym = decode_symbol(d, lt);
		if (sym > lt.max_sym) return error::DATA_ERROR?;

		switch (sym)
		{
			case 16:
				// copy previous code length 3-6 times (read 2 bits)
				if (num == 0) return error::DATA_ERROR?;
				sym = lengths[num - 1];
				length = getbits_base(d, 2, 3);
			case 17:
				// repeat code length 0 for 3-10 times (read 3 bits)
				sym = 0;
				length = getbits_base(d, 3, 3);
			case 18:
				// repeat code length 0 for 11-138 times (read 7 bits)
				sym = 0;
				length = getbits_base(d, 7, 11);
			default:
				// values 0-15 represent the actual code lengths
				length = 1;
		}

		if (length > hlit + hdist - num) return error::DATA_ERROR?;

		while (length--) lengths[num++] = (char)sym;
	}

	// check EOB symbol is present
	if (lengths[256] == 0) return error::DATA_ERROR?;

	// build dynamic trees
	build_tree(lt, lengths[..], hlit)!;
	build_tree(dt, lengths[hlit..], hdist)!;
}

// -- block inflate functions --

// given a stream and two trees, inflate a block of data
fn void? inflate_block_data(TinfData *d, TinfTree *lt, TinfTree *dt)
{
	// extra bits and base tables for length codes
	char[30] length_bits = {
		0, 0, 0, 0, 0, 0, 0, 0, 1, 1,
		1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
		4, 4, 4, 4, 5, 5, 5, 5, 0, 127
	};

	ushort[30] length_base = {
		 3,  4,  5,   6,   7,   8,   9,  10,  11,  13,
		15, 17, 19,  23,  27,  31,  35,  43,  51,  59,
		67, 83, 99, 115, 131, 163, 195, 227, 258,   0
	};

	// extra bits and base tables for distance codes
	char[30] dist_bits = {
		0, 0,  0,  0,  1,  1,  2,  2,  3,  3,
		4, 4,  5,  5,  6,  6,  7,  7,  8,  8,
		9, 9, 10, 10, 11, 11, 12, 12, 13, 13
	};

	ushort[30] dist_base = {
		   1,    2,    3,    4,    5,    7,    9,    13,    17,    25,
		  33,   49,   65,   97,  129,  193,  257,   385,   513,   769,
		1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
	};

	while LOOP: (true)
	{
		int sym = decode_symbol(d, lt);

		// check for overflow in bit reader
		if (d.overflow) return error::DATA_ERROR?;

		if (sym < 256)
		{
			if (d.dest == d.dest_end) return error::BUF_ERROR?;
			*(d.dest++) = (char)sym;
		}
		else
		{
			int length, dist, offs;
			int i;

			// check for end of block
			if (sym == 256) break LOOP;

			// Check sym is within range and distance tree is not empty
			if (sym > lt.max_sym || sym - 257 > 28 || dt.max_sym == -1) {
				return error::DATA_ERROR?;
			}

			sym -= 257;

			// Possibly get more bits from length code
			length = getbits_base(d, length_bits[sym], length_base[sym]);

			dist = decode_symbol(d, dt);

			// check dist is within range
			if (dist > dt.max_sym || dist > 29) {
				return error::DATA_ERROR?;
			}

			// possibly get more bits from distance code
			offs = getbits_base(d, dist_bits[dist], dist_base[dist]);

			if (offs > (d.dest - d.dest_start)) {
				return error::DATA_ERROR?;
			}

			if ((d.dest_end - d.dest) < length) {
				return error::BUF_ERROR?;
			}

			// copy match
			for (i = 0; i < length; i++) {
				d.dest[i] = d.dest[i - offs];
			}

			d.dest += length;
		}
	}
}

// inflate an uncompressed block of data
fn void? inflate_uncompressed_block(TinfData *d)
{
	uint length, invlength;

	if (d.source_end - d.source < 4) return error::DATA_ERROR?;

	length = read_le_ushort(io::wrap_bytes(d.source[:2]))!;

	invlength = read_le_ushort(io::wrap_bytes(d.source[2:2]))!;

	if (length != (~invlength & 0x0000FFFF)) return error::DATA_ERROR?;

	d.source += 4;

	if (d.source_end - d.source < length) return error::DATA_ERROR?;

	if (d.dest_end - d.dest < length)  return error::BUF_ERROR?;

	// copy block
	while (length--) {
		*d.dest++ = *d.source++;
	}

	// make sure we start next block on a byte boundary
	d.tag = 0;
	d.bitcount = 0;
}

// inflate a block of data compressed with fixed Huffman trees
fn void? inflate_fixed_block(TinfData *d)
{
	// build fixed Huffman trees
	build_fixed_trees(&d.ltree, &d.dtree);

	// decode block using fixed trees
	return inflate_block_data(d, &d.ltree, &d.dtree);
}

fn void? inflate_dynamic_block(TinfData *d)
{
	// decode trees from stream
	decode_trees(d, &d.ltree, &d.dtree)!;

	// decode block using decoded trees
	return inflate_block_data(d, &d.ltree, &d.dtree);
}

// inflate stream from source to dest
fn void? uncompress(char[] dest, char[] source)
{
	TinfData d;
	int bfinal;

	// unitialise data
	d.source = source.ptr;
	d.source_end = d.source + source.len;
	d.tag = 0;
	d.bitcount = 0;
	d.overflow = 0;

	d.dest = dest.ptr;
	d.dest_start = d.dest;
	d.dest_end = d.dest + dest.len;

	do {
		uint btype;

		// read final block flag
		bfinal = getbits(&d, 1);

		// read block type (2 bits)
		btype = getbits(&d, 2);

		// uecompress block
		switch (btype) {
		case 0:
			// decompress uncompressed block
			inflate_uncompressed_block(&d)!;
		case 1:
			// decompress block with fixed Huffman trees
			inflate_fixed_block(&d)!;
		case 2:
			// decompress block with dynamic Huffman trees
			inflate_dynamic_block(&d)!;
		default:
			return error::DATA_ERROR?;
		}

	} while (!bfinal);

	// Check for overflow in bit reader
	if (d.overflow) {
		return error::DATA_ERROR?;
	}

	dest = dest[:(usz)(d.dest - d.dest_start)];
}


