/*
 * Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
 * License: GNU General Public License v3 or later
 * See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>
 */

/* Thin wrapper over the system iconv(3) for SData_Core.Charset.  Going
   through <iconv.h> (rather than importing iconv_open from Ada) lets the
   header map the names on platforms whose iconv is GNU libiconv (macOS,
   Windows), where the real symbols are libiconv_open and friends. */

#include <errno.h>
#include <iconv.h>
#include <stddef.h>

/* Returns a conversion descriptor, or NULL when the system has no
   conversion between the two character sets. */
void *sdata_iconv_open (const char *to_code, const char *from_code)
{
    iconv_t cd = iconv_open (to_code, from_code);
    return cd == (iconv_t) -1 ? NULL : (void *) cd;
}

void sdata_iconv_close (void *cd)
{
    if (cd != NULL)
        iconv_close ((iconv_t) cd);
}

/* Converts all of in[0 .. in_len) into out[0 .. out_cap).  Status:
     0  success; *out_len bytes were written
     1  an input byte sequence is invalid (or unrepresentable in the target);
        *in_used is the offset of the first offending byte
     2  the input ends in the middle of a character; *in_used is its offset
     3  the output buffer is too small (retry with a larger one)
     4  any other failure
   The descriptor is returned to its initial shift state first and last, so
   one descriptor can convert many independent strings. */
int sdata_iconv_convert (void *cd, const char *in, size_t in_len,
                         char *out, size_t out_cap,
                         size_t *out_len, size_t *in_used)
{
    char  *ip = (char *) in;
    char  *op = out;
    size_t il = in_len;
    size_t ol = out_cap;
    size_t r;

    iconv ((iconv_t) cd, NULL, NULL, NULL, NULL);
    r = iconv ((iconv_t) cd, &ip, &il, &op, &ol);
    if (r != (size_t) -1)
        r = iconv ((iconv_t) cd, NULL, NULL, &op, &ol);   /* flush */
    *in_used = (size_t) (ip - in);
    *out_len = (size_t) (op - out);
    if (r != (size_t) -1)
        return 0;
    switch (errno) {
        case EILSEQ: return 1;
        case EINVAL: return 2;
        case E2BIG:  return 3;
        default:     return 4;
    }
}
