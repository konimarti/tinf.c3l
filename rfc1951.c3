module rfc;
import std::io, std::encoding, std::collections, tinf;

fn void main() => @pool()
{
	int[] codes = gen_huff();

	char[] s = "hello world";

	GrowableBitSet{char} encoded;
	encoded.tinit();
	// BFINAL 1
	// BTYPE  01
	encoded.set(0);
	encoded.set(2);
	usz pos = 3;

	foreach(c: s)
	{
		char code = (char)codes[c];
		for (int i = 0; i < 8; i++)
		{
			if ((code & (1<<i)) != 0) encoded.set(pos);
			pos++;
		}
	}

	encoded.set(pos+7);
	encoded.unset(pos+7);

	char[] input = encoded.data.array_view()[:13];

	char[16] output;
	inflate::uncompress(output[..], input)!!;
}

<*
 RFC 1951, Section 3.2.2. Use of Huffman coding in the "deflate" format
*>
fn int[] gen_huff()
{
	// Toy model in RFC:
	// int[*] lens = { 3, 3, 3, 3, 3, 2, 4, 4 };
	// char[*] sym = "ABCDEFGH";

	// Fixed Huffman codes (BTYPE=01)
	int[*] lens = {
		[  0..143] = 8,
		[144..255] = 9,
		[256..279] = 7,
		[280..287] = 8,
	};

        // 1)  Count the number of codes for each code length.  Let
        //     bl_count[N] be the number of codes of length N, N >= 1.

	HashMap{int, int} bl_count;
	bl_count.tinit();
	foreach (len: lens) bl_count[len] += 1;
	io::printfn("bl_count[N]: %s", bl_count);

        // 2)  Find the numerical value of the smallest code for each
        //     code length:

	const MAX_BITS = 16; // ??

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
	io::printfn("next_code[N]: %s", next_code);

        // 3)  Assign numerical values to all codes, using consecutive
        //     values for all codes of the same length with the base
        //     values determined at step 2. Codes that are never used
        //     (which have a bit length of zero) must not be assigned a
        //     value.

	int[] codes = mem::temp_array(int, lens.len);
	foreach (i, len: lens)
	{
		if (len == 0) continue;
		// io::printfn("%c\t%d\t%0*b", sym[i], len, len, next_code[len]);
		io::printfn("%4d\t%d\t%0*b", i, len, len, next_code[len]);
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
