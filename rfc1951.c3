module rfc;
import std::io, std::encoding, std::collections, tinf;

struct BitSetter
{
	List{char} list;
	usz pos;
}

fn void BitSetter.init(&self, Allocator allocator) => self.list.init(allocator);
fn void BitSetter.tinit(&self) => self.init(tmem);
fn void BitSetter.free(&self) => self.list.free();

fn void BitSetter.push(&self, char bit)
{
	usz index = self.pos / 8;
	usz offset = self.pos % 8;
	if (index >= self.list.len()) self.list.push(0);

	char b = self.list[index];
	// reg |= (1 << pos); → set a bit.
	// reg &= ~(1 << pos); → clear a bit.
	b = (bit == 1) ? b | (1UL << offset) : b & ~(+1UL << offset);

	self.list[index] = b;
	self.pos++;
}

fn void main() => @pool()
{
	int[] codes = gen_huff();

	char[] s = "hello world";
	// char[] s = {0, 0, 0, 0, 0, 0, 0, 0};

	// Encoding a byte
	char eb = 0;
	eb |= 0b101;
	io::printfn("encoded byte: %08b", eb);
	io::printfn("encoded byte: %x", eb);

	BitSetter bs;
	bs.tinit();

	// BFINAL 1 + BTYPE  01 will read ..011 from right to left
	bs.push(1);
	bs.push(1);
	bs.push(0);

	foreach(c: s)
	{
		char code = (char)codes[c];
		io::printfn("code: %08b", code);
		for (int i = 7; i >= 0; i--)
		{
			bool bit_set = ((code & (1UL<<i)) != 0);
			io::printfn("bit %d is %s", i, bit_set);
			bs.push(bit_set ? 1 : 0);
		}
	}

	// Add end of block code 256
	char code = (char)codes[256];
	io::printfn("end-of-block code: %08b", code);
	for (int i = 7; i >= 0; i--)
	{
		bool bit_set = ((code & (1UL<<i)) != 0);
		io::printfn("bit %d is %s", i, bit_set);
		bs.push(bit_set ? 1 : 0);
	}

	foreach (i, b : bs.list)
	{
		io::printfn("bytes %d: 0x%02x 0b%08b", i, b, b);
	}

	char[16] output;
	inflate::uncompress(output[..], bs.list.array_view())!!;

	io::printfn("uncompressed: '%s'", (String)output[..]);

	assert((String)s[:s.len] == (String)output[:s.len]);
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
