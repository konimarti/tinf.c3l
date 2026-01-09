module rfc;
import std::io, std::encoding, std::collections, tinf;

struct DynamicBitList
{
	List{char} list;
	usz pos;
}

fn void DynamicBitList.init(&self, Allocator allocator) => self.list.init(allocator);
fn void DynamicBitList.tinit(&self) => self.init(tmem);
fn void DynamicBitList.free(&self) => self.list.free();

enum BitState { UNSET, SET }
fn void DynamicBitList.push_bit(&self, BitState bit)
{
	usz index = self.pos / 8;
	usz offset = self.pos % 8;
	if (index >= self.list.len()) self.list.push(0);

	char b = self.list[index];
	b = (bit == SET) ? b | (1UL << offset) : b & ~(+1UL << offset);

	self.list[index] = b;
	self.pos++;
}

<*
 @require pos >= 0 && pos <= 32 : "Pos needs to be between 0 and 32."
*>
macro BitState get_bit_state(uint b, isz pos)
{
	return (b & (1UL<<pos)) != 0 ? BitState.SET : BitState.UNSET;
}

<*
 @param b        : "Bits to be pushed"
 @param num_bits : "Number of bits to push"
 @param lsb      : "Order from which side to start pushing bits"
 @require num_bits > 0   : "Number of bits must be at least 1"
 @require num_bits <= 32 : "Number of bits can not be larger than 32"
*>
fn void DynamicBitList.push(&self, uint b, usz num_bits, bool lsb = true)
{
	isz start, end;
	start = 0;
	end   = num_bits - 1;
	if (lsb)
	{
		for (isz i = start; i <= end; i+= lsb ? 1 : -1)
		{
			self.push_bit(get_bit_state(b, i));
		}
	}
	else
	{
		for (isz i = end; i >= start; i--)
		{
			self.push_bit(get_bit_state(b, i));
		}
	}
}

fn void main()
{
	no_compression();
	fixed_huff();
	dynamic_huff();
}

// macro void? write_le_16(stream, ushort s)
// {
// 	stream.write_byte((char)s)!;
// 	stream.write_byte((char)(s >> 8))!;
// }

import std::math;
fn void no_compression() => @pool()
{
	io::printn("-- no compression --");
	// char[] input = "hello world";
	char[1024] input;
	foreach (i, &e : input) *e = (char)(i % 255);
	char[] encoded = nocomp_encode(input[..], tmem);
	verify(encoded, input[..], "no_comp");
}

<*
 TODO: Enforce max block size of 65'535 as defined in the RFC.
*>
fn char[] nocomp_encode(char[] input, Allocator allocator) => @pool()
{
	DynamicBitList bs;
	bs.tinit();

	// Set Block header
	// Push BFINAL (0b1) and BTYPE (0b00) as 0x001 [read from right to left]
	bs.push(0b001, 8);

	// Encode len (deflate rfc packes data elements into bytes as lsb) If
	// input.len does not fit an ushort, we have to create multiple blocks
	ushort len = (ushort)input.len;
	bs.push((char)len, 8, lsb: true);
	bs.push((char)(len>>8), 8, lsb: true);

	ushort nlen = ~len;
	bs.push((char)nlen, 8, lsb: true);
	bs.push((char)(nlen>>8), 8, lsb: true);

	// Encode data
	foreach(c: input)
	{
		bs.push(c, 8, lsb: true);
	}

	foreach (i, b : bs.list)
	{
		io::printfn("bytes %2d: 0x%02x 0b%08b", i, b, b);
	}

	return bs.list.to_array(allocator);
}

fn void dynamic_huff() => @pool()
{
	io::printn("-- dynamic huffman encoding --");

	// Fixed Huffman codes bit_len
	int[*] bit_len = {
		[  0..143] = 8,
		[144..255] = 9,
		[256..279] = 7,
		[280..287] = 8,
	};

	// Generate the fixed Huffman codes
	uint[] huff_codes = gen_huff(bit_len[..]);

	// Distance codes bit_len
	int[*] dist_len = {
		[0..32] = 5,
	};

	// Generate the distance codes
	uint[] dist_codes = gen_huff(bit_len[..]);

	// Input string to be deflated
	char[] s = "hello world";

	// Encode string
	char[] encoded = dynamic_huff_encode(s,
			huff_codes, bit_len[..],
			dist_codes, dist_len[..],
		tmem);

	verify(encoded, s, "dynamic_huff");
}

fn char[] dynamic_huff_encode(char[] input, uint[] codes, int[] len,
					uint[]dist_codes, int[] dist_len,
			Allocator allocator) => @pool()
{
	DynamicBitList bs;
	bs.tinit();

	// Set Block header
	// Push BFINAL (0b1) and BTYPE (0b10) as 0x101 [read from right to left]
	bs.push(0b101, 3);

	// Push 5 bits HLIT (# of literal/length codes - 257)
	bs.push(codes.len-257-2, 5, true);

	// Push 5 bits HDIST (# of distance codes - 1)
	bs.push(dist_codes.len-1-2, 5, true);

	// Push 4 bits HCLEN (# of code length codes - 4)
	bs.push(19-4, 4, true);

	// Create Huff codes for hc
	int hc_bit_len = 7;
	int[*] hc_len = { [0..18] = hc_bit_len };
	uint[] hc_codes = gen_huff(hc_len[..]);
	uint[] hc_order = {
		16, 17, 18,  0,  8,
		 7,  9,  6, 10,  5,
		11,  4, 12,  3, 13,
	 	 2, 14,  1, 15 };

	// Assume for now that we use all 19 codes with a code bit length of 3
	// bits
	for (usz i = 0; i < 19; i++)
	{
		// bs.push(hc_len[hc_order[i]], 3, true);
		bs.push(hc_len[hc_order[i]], 3, true);
	}

	// Now save the literal/length tree, hc-encoded
	foreach(l: len)
	{
		bs.push(hc_codes[hc_order[l]], hc_bit_len, false);
	}

	// Now save the distance/tree, hc-encoded
	foreach(l: dist_len)
	{
		bs.push(hc_codes[hc_order[l]], hc_bit_len, false);
	}

	// And finally the compressed data
	foreach(c: input)
	{
		bs.push(codes[c], len[c], false);
	}

	// Add end of block code 256
	bs.push(codes[256], len[256], false);

	foreach (i, b : bs.list)
	{
		io::printfn("bytes %2d: 0x%02x 0b%08b", i, b, b);
	}

	return bs.list.to_array(allocator);
}

<*
 TODO: Entire LZ (length/distance) pairs part is currently not implemented.
*>
fn void fixed_huff() => @pool()
{
	io::printn("-- fixed huffman encoding --");

	// Fixed Huffman codes bit_len
	int[*] bit_len = {
		[  0..143] = 8,
		[144..255] = 9,
		[256..279] = 7,
		[280..287] = 8,
	};

	// Generate the fixed Huffman codes
	uint[] huff_codes = gen_huff(bit_len[..]);

	// Distance codes dist_len
	int[*] dist_len = {
		[  0..32] = 5,
	};

	// Generate the distance codes
	uint[] dist_codes = gen_huff(dist_len[..]);

	// Input string to be deflated
	char[] s = "hello world";

	// Encode string
	char[] encoded = fixed_huff_encode(s, huff_codes, bit_len[..], tmem);

	verify(encoded, s, "fixed_huff");
}

fn void verify(char[] encoded, char[] input, String test_name)
{
	// Decompress with inflate
	char[1024] output;
	inflate::uncompress(output[..], encoded)!!;
	// io::printfn("uncompressed: '%s'", (String)output[..]);

	String want = (String)input[:input.len];
	String got = (String)output[:input.len];
	assert(want == got, "%s failed: want: %s, got: %s", test_name, want, got);

	io::printfn("SUCCESS: %s", test_name);
}

<*
 Encode char[] with the provided Huffman codes and bit lengths.
 @require codes.len == len.len
*>
fn char[] fixed_huff_encode(char[] input, uint[] codes, int[] len, Allocator allocator) => @pool()
{
	DynamicBitList bs;
	bs.tinit();

	// Set Block header
	// Push BFINAL (0b1) and BTYPE (0b01) as 0x011 [read from right to left]
	bs.push(0b011, 3);

	foreach(c: input)
	{
		bs.push(codes[c], len[c], false);
	}

	// Add end of block code 256
	bs.push(codes[256], len[256], false);

	foreach (i, b : bs.list)
	{
		io::printfn("bytes %2d: 0x%02x 0b%08b", i, b, b);
	}

	return bs.list.to_array(allocator);
}

<*
 RFC 1951, Section 3.2.2. Use of Huffman coding in the "deflate" format
 require bit_len.len == 288 || bit_len.len == 19: "Code bit_len array must contain exactly 288 or 19 elements"

 @param bit_len : "Array with bit bit_len of Huffman codes"
 @return "Huffman codes"
*>
fn uint[] gen_huff(int[] bit_len)
{
	// Toy model in RFC:
	// int[*] bit_len = { 3, 3, 3, 3, 3, 2, 4, 4 };
	// char[*] sym = "ABCDEFGH";

        // 1)  Count the number of codes for each code length.  Let
        //     bl_count[N] be the number of codes of length N, N >= 1.

	HashMap{int, int} bl_count;
	bl_count.tinit();
	foreach (len: bit_len) bl_count[len] += 1;
	// io::printfn("bl_count[N]: %s", bl_count);

        // 2)  Find the numerical value of the smallest code for each
        //     code length:

	const MAX_BITS = 32; // ??

	List{int} next_code;
	next_code.tinit();
	next_code.push(0); // Move index to 1

	int code = 0;
	bl_count[0] = 0;
	for (int bits = 1; bits <= MAX_BITS; bits++)
	{
	        code = (code + bl_count[bits-1] ?? 0) << 1;
	        next_code.push(code);
	}
	// io::printfn("next_code[N]: %s", next_code);

        // 3)  Assign numerical values to all codes, using consecutive
        //     values for all codes of the same length with the base
        //     values determined at step 2. Codes that are never used
        //     (which have a bit length of zero) must not be assigned a
        //     value.

	uint[] codes = mem::temp_array(uint, bit_len.len);
	foreach (i, len: bit_len)
	{
		if (len == 0) continue;
		// io::printfn("%4d\t%d\t%0*b", i, len, len, next_code[len]);
		codes[i] = next_code[len];
		next_code[len]++;
	}
	return codes;
}

/*
 3.2.3 Details of block format

 first bit	BFINAL
 next 2 bits	BTYPE

 BFINAL only set if is the last block of the data set.

 BTYPE specifies how the data are compressed:

 	00 - no compression
	01 - fixed Huffman codes
	10 - dynamic Huffman codes
	11 - reserved (error)

3.2.4. Non-compressed blocks (BTYPE=00)

         Any bits of input up to the next byte boundary are ignored.
         The rest of the block consists of the following information:

              0   1   2   3   4...
            +---+---+---+---+================================+
            |  LEN  | NLEN  |... LEN bytes of literal data...|
            +---+---+---+---+================================+

         LEN is the number of data bytes in the block.  NLEN is the
         one's complement of LEN.
*/
