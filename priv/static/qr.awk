#!/usr/bin/gawk -f
# qr.awk - QR code encoder in pure GNU awk
# Usage: echo "https://example.com" | gawk -f qr.awk
# Displays QR code using Unicode half-blocks. Dark terminal assumed.

BEGIN {
    val = 1
    for (i = 0; i < 255; i++) {
        EXP[i] = val; LOG[val] = i
        val *= 2; if (val >= 256) val = xor(val, 285)
    }
    EXP[255] = EXP[0]
    split("21 25 29 33", VSIZE)
    split("19 34 55 80", VDATA)
    split("7 10 15 20", VEC)
    for (i = 0; i < 256; i++) ORD[sprintf("%c", i)] = i
}

function gf_mul(a, b) {
    if (a == 0 || b == 0) return 0
    return EXP[(LOG[a] + LOG[b]) % 255]
}

function set_mod(r, c, v) { M[r,c] = v; USED[r,c] = 1 }

function place_finder(r0, c0,    r, c) {
    for (r = 0; r < 7; r++)
        for (c = 0; c < 7; c++)
            set_mod(r0+r, c0+c, \
                (r==0||r==6||c==0||c==6||(r>=2&&r<=4&&c>=2&&c<=4)) ? 1 : 0)
}

{
    url = $0; gsub(/[\r\n]/,"",url); ulen = length(url)

    ver = 0
    for (v = 1; v <= 4; v++) {
        if (4 + 8 + ulen*8 <= VDATA[v]*8) { ver = v; break }
    }
    if (!ver) { print "URL too long (max ~78 chars)" > "/dev/stderr"; exit 1 }

    sz = VSIZE[ver]; nd = VDATA[ver]; ne = VEC[ver]

    # Encode bitstream (byte mode 0100)
    delete BIT; nb = 0
    BIT[nb++]=0; BIT[nb++]=1; BIT[nb++]=0; BIT[nb++]=0
    for (i=7;i>=0;i--) BIT[nb++] = int(ulen/lshift(1,i)) % 2
    for (i=1;i<=ulen;i++) {
        ch = ORD[substr(url,i,1)]
        for (j=7;j>=0;j--) BIT[nb++] = int(ch/lshift(1,j)) % 2
    }
    for (i=0;i<4&&nb<nd*8;i++) BIT[nb++]=0
    while(nb%8) BIT[nb++]=0
    pb=0; while(nb<nd*8) {
        v=pb?17:236
        for(i=7;i>=0;i--) BIT[nb++]=int(v/lshift(1,i))%2
        pb=!pb
    }

    delete DB
    for(i=0;i<nd;i++) { v=0; for(j=0;j<8;j++) v=v*2+BIT[i*8+j]; DB[i]=v }

    # Reed-Solomon
    delete GEN; GEN[0]=1; gl=1
    for(i=0;i<ne;i++) {
        for(j=gl;j>=1;j--) GEN[j]=xor(+GEN[j-1], gf_mul(+GEN[j], EXP[i]))
        GEN[0]=gf_mul(GEN[0], EXP[i]); gl++
    }
    delete MSG
    for(i=0;i<nd;i++) MSG[i]=DB[i]
    for(i=nd;i<nd+ne;i++) MSG[i]=0
    for(i=0;i<nd;i++) {
        fb=MSG[i]
        if(fb) for(j=0;j<ne;j++) MSG[i+j+1]=xor(MSG[i+j+1], gf_mul(fb, GEN[ne-1-j]))
    }
    delete CW
    for(i=0;i<nd;i++) CW[i]=DB[i]
    for(i=0;i<ne;i++) CW[nd+i]=MSG[nd+i]
    tcw=nd+ne

    # Build matrix
    delete M; delete USED; delete FRES; delete FUNC
    place_finder(0,0); place_finder(0,sz-7); place_finder(sz-7,0)

    for(i=0;i<8;i++) {
        set_mod(7,i,0); set_mod(i,7,0)
        set_mod(7,sz-8+i,0); set_mod(i,sz-8,0)
        set_mod(sz-8,i,0); set_mod(sz-8+i,7,0)
    }
    for(i=8;i<sz-8;i++) {
        if(!USED[6,i]) set_mod(6,i,i%2==0?1:0)
        if(!USED[i,6]) set_mod(i,6,i%2==0?1:0)
    }
    if(ver>=2) {
        if(ver==2){ap1=6;ap2=18} if(ver==3){ap1=6;ap2=22} if(ver==4){ap1=6;ap2=26}
        split(ap1" "ap2, APS)
        for(ai=1;ai<=2;ai++) for(aj=1;aj<=2;aj++) {
            ar=APS[ai]; ac=APS[aj]
            if(USED[ar,ac]) continue
            for(dr=-2;dr<=2;dr++) for(dc=-2;dc<=2;dc++)
                set_mod(ar+dr,ac+dc,(dr==-2||dr==2||dc==-2||dc==2||(dr==0&&dc==0))?1:0)
        }
    }
    set_mod(sz-8,8,1)

    for(i=0;i<=8;i++) {
        if(i<8) {
            if(!USED[8,i]){USED[8,i]=1;FRES[8,i]=1}
            if(!USED[i,8]){USED[i,8]=1;FRES[i,8]=1}
        }
        if(i<8&&!USED[8,sz-1-i]){USED[8,sz-1-i]=1;FRES[8,sz-1-i]=1}
        if(i<8&&!USED[sz-1-i,8]){USED[sz-1-i,8]=1;FRES[sz-1-i,8]=1}
    }
    if(!USED[8,8]){USED[8,8]=1;FRES[8,8]=1}

    for(r=0;r<sz;r++) for(c=0;c<sz;c++) if(USED[r,c]) FUNC[r,c]=1

    # Place data
    bi=0; upward=1
    for(col=sz-1;col>=0;col-=2) {
        if(col==6) col=5
        for(ri=0;ri<sz;ri++) {
            row=upward?(sz-1-ri):ri
            for(ci=0;ci<2;ci++) {
                cc=col-ci
                if(cc<0||USED[row,cc]) continue
                if(bi<tcw*8) {
                    byi=int(bi/8);bpi=7-(bi%8)
                    M[row,cc]=int(CW[byi]/lshift(1,bpi))%2
                } else M[row,cc]=0
                USED[row,cc]=1; bi++
            }
        }
        upward=!upward
    }

    # Mask 0: (r+c)%2==0
    for(r=0;r<sz;r++) for(c=0;c<sz;c++) {
        if(FUNC[r,c]||FRES[r,c]) continue
        if((r+c)%2==0) M[r,c]=1-M[r,c]
    }

    # Format info: L(01) mask0(000) → precomputed BCH+XOR = 111011111000100
    fmt="111011111000100"
    split("0 1 2 3 4 5 7 8",FC); for(i=1;i<=8;i++) M[8,FC[i]]=int(substr(fmt,i,1))
    split("0 1 2 3 4 5 7",FR); for(i=1;i<=7;i++) M[FR[i],8]=int(substr(fmt,15-i+1,1))
    M[8,8]=int(substr(fmt,8,1))
    for(i=0;i<8;i++) M[8,sz-8+i]=int(substr(fmt,8+i,1))
    for(i=0;i<7;i++) M[sz-7+i,8]=int(substr(fmt,i+1,1))

    # Output (inverted for dark terminal: QR dark→space, QR light→block)
    q = 4
    for(r=-q;r<sz+q;r+=2) {
        line=""
        for(c=-q;c<sz+q;c++) {
            t=(r>=0&&r<sz&&c>=0&&c<sz) ? M[r,c]+0 : 0
            b=((r+1)>=0&&(r+1)<sz&&c>=0&&c<sz) ? M[r+1,c]+0 : 0
            # Invert: 0=light=█, 1=dark=space
            if(!t&&!b) line=line "\xe2\x96\x88"
            else if(!t&&b) line=line "\xe2\x96\x80"
            else if(t&&!b) line=line "\xe2\x96\x84"
            else line=line " "
        }
        print line
    }
}
