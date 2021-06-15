/******************************************************************
 *  synth.fx for Reshade 4+ by kingeric1992
 *                                      update: June.1.2021
 ******************************************************************/

#define KEY_PAUSE VK_P // space
#define KEY_RESET VK_R // R

#include "macro_vk.fxh"


#define LINSEG (BUFFER_WIDTH - 1)
#define LINEROW (BUFFER_HEIGHT)

namespace synth
{
/******************************************************************
 *  assests
 ******************************************************************/

    uniform float   gFov        < ui_type="slider"; ui_min=1; ui_max=179; ui_step=1;>   = 75;
    uniform float   gAmp        < ui_type="slider"; ui_min=0; ui_max=10; > = 1;


    uniform float   gMovSpeed   < ui_label="mov speed.";   ui_min = 0; ui_max = 10; > = 1;
    uniform float   gMseSpeed   < ui_label="mse sensitivity"; ui_min = 0; ui_max = 10; > = 0.1;

    uniform float   gPause      < source="key"; keycode = KEY_PAUSE; mode = "toggle";>;
    uniform bool    gForward    < source="key"; keycode = VK_W;>;
    uniform bool    gBack       < source="key"; keycode = VK_S;>;
    uniform bool    gLeft       < source="key"; keycode = VK_A;>;
    uniform bool    gRight      < source="key"; keycode = VK_D;>;
    uniform bool    gUp         < source="key"; keycode = VK_SPACE;>;
    uniform bool    gDown       < source="key"; keycode = VK_CONTROL;>;
    uniform bool    gReset      < source="key"; keycode = KEY_RESET; >;

    uniform float   gLMB        < source="mousebutton"; keycode = 0x00;>; //LMB
    uniform float   gRMB        < source="mousebutton"; keycode = 0x01;>; //RMB
    uniform float   gMMB        < source="mousebutton"; keycode = 0x04;>; //MMB
    uniform float2  gDelta      < source="mousedelta";>;
    uniform float2  gWheel      < source="mousewheel";>; // .y is delta
    uniform float   gFrameTime  < source="frametime";>;

    static const float2 gAspect = float2(BUFFER_HEIGHT * BUFFER_RCP_WIDTH,1);

    #define ADDRESS(a) AddressU = a; AddressV = a; AddressW = a
    #define FILTER(a)  MagFilter = a; MinFilter = a; MipFilter = a

    texture2D texCol  : COLOR;
    texture2D texEye { Format=RGBA32F; Width=2; };
    texture2D texUpd { Format=RGBA32F; Width=2; };
    texture2D texDep { Format=R32F; Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; };

    sampler2D sampCol { Texture=texCol; };
    sampler2D sampEye { Texture=texEye; FILTER(POINT); };
    sampler2D sampUpd { Texture=texUpd; FILTER(POINT); };
    sampler2D sampDep { Texture=texDep; FILTER(POINT); };

    #define PI  3.1415926
    #define PI2 6.2831853

/******************************************************************
 *  helpers
 ******************************************************************/
    float2   sincos(float r) { float2 sc; return sincos(r,sc.x,sc.y), sc; } // sin, cos
    float2   rotR(float2 p, float r) { float2 sc = sincos(r); return mul(float2x2(sc.y,-sc.x,sc), p); }
    float3x3 rotX(float r) { float2 sc = sincos(r); return float3x3( 1,0,0, 0,sc.y,-sc.x, 0,sc.x,sc.y); }
    float3x3 rotY(float r) { float2 sc = sincos(r); return float3x3( sc.y,0,sc.x, 0,1,0, -sc.x,0,sc.y); }
    float3x3 rotZ(float r) { float2 sc = sincos(r); return float3x3( sc.y,-sc.x,0, sc.x,sc.y,0, 0,0,1); }
    float3x3 rotXYZ(float3 r) { return mul(mul(rotZ(r.z),rotY(r.y)),rotX(r.x)); }
    float2   map2D(float id, float n) { float2 r; r.x = trunc(id/n), r.y = id - r.x * n; return r.yx; }

    // rotate quaternion a by quaternion b
    float4 mulQ(float4 a, float b) {
        const float2 k = float2(1,-1);
        return mul(a.wxyz, float4x4( b, b.wzyx * k.xyxy, b.zwxy * k.xxyy, b.yxwz * k.yxxy ));
    }
    float4 conjQ(float4 q) { return float4(-q.xyz, q.w);}

    float3x3 rot(float4 q) {
        float n = length(q);
        q = n==0? 0: ( q * sqrt(2.) / n);
        float3 W = q.w * q.xyz;
        float3 X = q.x * q.xyz;
        float3 Y = q.y * q.xyz;
        float3 Z = q.z * q.xyz;
        return float3x3(
            1 - (Y.y + Z.z), X.y - W.z, X.z + W.y,
            X.y + W.z, 1 - (X.x + Z.z), Y.z - W.x,
            X.z - W.y, Y.z + W.x, 1 - (X.x + Y.y)
        );
    }
    float4x4 mView( float3x3 _m, float3 _e) {
        return float4x4(
            _m[0], -dot(_m[0],_e),
            _m[1], -dot(_m[1],_e),
            _m[2], -dot(_m[2],_e),
            0,0,0,1
        );
    }
    float4x4 mView( float3 _r, float3 _e) { return mView(rotXYZ(_r)); }
    float4x4 mView( float4 _q, float3 _e) { return mView(rot(_q)); }
    float4x4 mProj() {
        float zF = 20;
        float zN = 0.01;
        float t  = zN/(zF-zN);
        float sY = rcp(tan(radians(gFov*.5)));
        float sX = sY * BUFFER_HEIGHT * BUFFER_RCP_WIDTH;
        return float4x4(sX,0,0,0, 0,sY,0,0, 0,0,-t,t*zF, 0,0,1,0);
    }

/******************************************************************
 *  controls
 ******************************************************************/

    // quaternion
    float4 getRot() { return tex2Dfetch(sampEye, int2(0,0)); }
    float3 getEye() { return tex2Dfetch(sampEye, int2(1,0)).xyz; }

    // roll when holding MMB
    float4 updRot( float4 q)
    {
        float3 d = float3(gLMB*gDelta, gMMB*atan2(r.y,r.x)) * gFrameTime * gMseSpeed * .0001;
        float3x3 m = transpose(rot(q)); // row[0] = x' axis, row[1] = y' axis, row[2] = z' axis
        q = mulQ(q, float4(m[1],1) * sincos(d.x).xxxy); // delta x is rotate about y' axis
        q = mulQ(q, float4(m[0],1) * sincos(d.y).xxxy); // delta y is rotate about x' axis
        //q = mulQ(q, float4(m[2],1) * sincos(d.z).xxxy); // delta z is rotate about z' axis
        return gReset? float4(0,sin(PI/2.),0, cos(PI/2.)) :q; // default is rotate about y by 180 degree.
    }
    float4 updEye( float4 q )
    {
        // rotate offset from view space to world space
        float3 eye = mul(float3(gRight - gLeft, 0, gBack- gForward), rot(q)) + float3(0,0, gUp - gDown);
        return gReset? float4(0,0,2,0): float4(clamp(eye * gFrameTime * .001 * gMovSpeed + getEye(), -200, 200),0);
    }
    float4 vs_ctrl( uint vid : SV_VERTEXID ) : SV_POSITION { return float4( vid * 2. - 1.,0,0,1); }
    float4 ps_upd( float4 vpos : SV_POSITION ) : SV_TARGET {
        return vpos.x < 1.? updRot(getRot()) : updEye(getRot());
    }
    float3 ps_eye( float4 vpos : SV_POSITION ) : SV_TARGET { return tex2Dfetch(sampUpd,vpos.xy).xyz; }

/******************************************************************
 *  transforms
 ******************************************************************/
    float4 transform(float4 vpos) { return mul(mProj(),mul(getView(getRot(),getEye()),vpos)); }

    // point generation
    float4 getPosP(uint vid, out float4 col, out float2 uv) {
        float4 pos;
        pos.xy = map2D(vid, BUFFER_WIDTH);
        pos.z  = dot( col.rgb = tex2Dfetch(sampCol, pos.xy).rgb, .333 * gAmp); // height by lum
        pos.w  = 1;

        uv = pos.xy *= float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT); //uv = map2D(vid, 2);
        col.a = 1;

        pos.xy = pos.xy * 2. - 1.;
        pos.y *= BUFFER_RCP_WIDTH * BUFFER_HEIGHT;
        return pos;
    }
    // line generation
    float4 getPosL(uint vid, out float4 col, out float2 uv) {
        float4 pos;
        float2 lid = map2D(vid, (LINESEG + 3)); // lid.x <- [0, LINESEG + 2]

        col.a = step(.5,lid.x) * step(lid.x, LINESEG + 1.5); 

        uv.x = saturate((lid.x - 1.) / LINESEG );
        uv.y = lid.y / (LINEROW - 1);
        
        pos.w  = 1;
        pos.z  = dot(col.rgb = tex2D(samoCol, uv).rgb, .333 * gAmp);
        pos.xy = uv.xy * float2(2,-2) + float2(-1,1);
        pos.y *= BUFFER_RCP_WIDTH * BUFFER_HEIGHT;
        return pos;
    }

/******************************************************************
 *  shaders
 ******************************************************************/

    // depth map
    float4 vs_depth_p(uint vid : SV_VERTEXID) : SV_POSITION {
        float3 _; return transform(getPosP(vid, _, _.xy));
    }
    // culling points in vs to stop ps init
    // comparing screenspace z (clip.z / clip.w) with depth buffer
    float4 vs_point(uint vid : SV_VERTEXID, out float4 col : TEXCOORD0) : SV_POSITION {
        float2 _;
        float4 pos = getPosP(vid, col, _), vpos = transform(pos);
        return vpos;
        //return vpos.z/vpos.w > tex2Dfetch(sampDep, pos.xy)? float4(0,0,-1,1) : vpos;
    }
    float4 ps_point( float4 vpos : SV_POSITION, float4 col : TEXCOORD0) : SV_TARGET { return col; }


    float4 vs_depth_l(uint vid : SV_VERTEXID) : SV_POSITION {
        float3 _; return transform(getPosL(vid, _, _.xy));
    }
    float4 vs_line(uint vid : SV_VERTEXID, out float4 col : TEXCOORD0) : SV_POSITION {
        float2 _; return transform(getPosL(vid, col, _));
    }
    // per pixel depth test. would alpha blend faster then discard?
    float4 ps_line( float4 vpos : SV_POSITION, float4 col : TEXCOORD0) : SV_TARGET {
        return /*(col.a = tex2Dfetch(sampDep, vpos.xy) > vpos.z? 0:col.a), */ col;
    }


    // write screenspace z to depth buffer
    // SV_POSITION z component is screenspace z (clip.z / clip.w), w component is clipspace w (clip.w).
    float  ps_depth( float4 vpos : SV_POSITION ) : SV_TARGET { return vpos.z; }

/******************************************************************
 *  technique
 ******************************************************************/

    technique synth
    {
        pass upd {
            PrimitiveTopology   = LINELIST;
            VertexCount         = 2;
            VertexShader        = vs_ctrl;
            PixelShader         = ps_upd;
            RenderTarget        = texUpd;
        }
        pass eye {
            PrimitiveTopology   = LINELIST;
            VertexCount         = 2;
            VertexShader        = vs_ctrl;
            PixelShader         = ps_eye;
            RenderTarget        = texEye;
        }
    #ifdef LINES
        // pass depth {
        //     VertexCount         = (LINESEG + 2) * LINEROW;
        //     PrimitiveTopology   = LINESTRIP;
        //     VertexShader        = vs_depth_l;
        //     PixelShader         = ps_depth;

        //     ClearRenderTargets  = true;
        //     RenderTarget	    = texDep;
        //     BlendEnable 	    = true;
        //     BlendOp			    = Min;
        //     DestBlend		    = ONE;
        // }
        pass lines {
            VertexCount             = (LINESEG + 3) * LINEROW;
            PrimitiveTopology       = LINESTRIP;
            VertexShader            = vs_line;
            PixelShader             = ps_line;
            BlendEnable             = true;
            SrcBlend                = SRCALPHA;
            DestBlend               = INVSRCALPHA;
            RenderTargetWriteMask   = 7;
        }
    #else
        // pass depth {
        //     VertexCount         = BUFFER_WIDTH * BUFFER_HEIGHT;
        //     PrimitiveTopology   = POINTLIST;
        //     VertexShader        = vs_depth_p;
        //     PixelShader         = ps_depth;

        //     ClearRenderTargets  = true;
        //     RenderTarget	    = texDep;
        //     BlendEnable 	    = true;
        //     BlendOp			    = Min;
        //     DestBlend		    = ONE;
        // }
        pass points {
            ClearRenderTargets      = true;
            VertexCount             = BUFFER_WIDTH * BUFFER_HEIGHT;
            PrimitiveTopology       = POINTLIST;
            VertexShader            = vs_point;
            PixelShader             = ps_point;
            BlendEnable             = true;
            SrcBlend                = SRCALPHA;
            DestBlend               = INVSRCALPHA;
            RenderTargetWriteMask   = 7;
        }
    #endif
    }
}
