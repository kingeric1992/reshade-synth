/******************************************************************
 *  synth.fx for Reshade 4+ by kingeric1992
 *                                      update: June.1.2021
 ******************************************************************/

#define KEY_PAUSE VK_P // space
#define KEY_RESET VK_R // R

#include "macro_vk.fxh"

#define ARCBALL

#define POINTSEG (BUFFER_WIDTH/2)
#define POINTROW (BUFFER_HEIGHT/2)

#define LINESEG  240 //(BUFFER_WIDTH - 1)
#define LINEROW  180 //(BUFFER_HEIGHT)

#define TRIGSEG  160
#define TRIGROW  90

namespace synth
{
/******************************************************************
 *  assests
 ******************************************************************/

    uniform float   gFov        < ui_type="slider"; ui_min=1; ui_max=179; ui_step=1;>   = 75;
    uniform float   gAmp        < ui_type="slider"; ui_min=0; ui_max=1; > = 1;

    uniform bool    gGrid       < ui_label="draw gridline";> = true;
    uniform float   gMovSpeed   < ui_label="mov speed.";   ui_min = 0; ui_max = 10; > = 1;
    uniform float   gMseSpeed   < ui_label="mse sensitivity"; ui_min = 0; ui_max = 10; > = 0.1;

    uniform float   gPause      < source="key"; keycode = KEY_PAUSE; mode = "toggle";>;
    uniform bool    gForward    < source="key"; keycode = VK_W;>;
    uniform bool    gBack       < source="key"; keycode = VK_S;>;
    uniform bool    gLeft       < source="key"; keycode = VK_A;>;
    uniform bool    gRight      < source="key"; keycode = VK_D;>;
    uniform bool    gUp         < source="key"; keycode = VK_SPACE;>;
    uniform bool    gDown       < source="key"; keycode = VK_CONTROL;>;
    uniform bool    gHand       < source="key"; keycode = VK_H;>;

    uniform float   gLMB        < source="mousebutton"; keycode = 0x00;>; //LMB
    uniform float   gRMB        < source="mousebutton"; keycode = 0x01;>; //RMB
    uniform float   gMMB        < source="mousebutton"; keycode = 0x04;>; //MMB
    uniform float2  gPoint      < source="mousepoint"; >;
    uniform float2  gDelta      < source="mousedelta";>;
    uniform float2  gWheel      < source="mousewheel";>; // .y is delta
    uniform float   gFrameTime  < source="frametime";>;
    uniform bool    gOverlay    < source="overlay_open";>;
    uniform float   gTimer      < source="timer"; >;
    uniform int     gActive     < source="overlay_active"; >;
    //uniform bool    gHovered    < source=

    static const float2 gAspect = float2(BUFFER_HEIGHT * BUFFER_RCP_WIDTH,1);
    static const float2 gSizeR  = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    static const float2 gSize   = float2(BUFFER_WIDTH, BUFFER_HEIGHT);

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
    float2   map2D(uint id, uint n) { float2 r; r.x = id/n, r.y = id - r.x * n; return r.yx; }
    // rodrigues rotation about axis with angle
    float3   rotR(float3 v, float3 a, float r) {
        float2 sc = sincos(r); return v*sc.y + cross(a,v) * sc.x + a * dot(a,v) * (1. - sc.y);
    }
    // rodrigues rotation matrix from axis and angle
    float3x3 rot(float3 a, float r) {
        float2  sc = sincos(r);
        float3x3 i = float3x3( 1,0,0, 0,1,0, 0,0,1);
        float3x3 k = float3x3( 0, -a.z, a.y, a.z, 0, -a.x, -a.y, a.x, 0 );
        return i + sc.x * k + (1. - sc.y) * mul(k,k);
    }
    float4 quat(float3 a, float r) { r/=2.; return float4(a*sin(r),cos(r)); }
    // rotate quaternion a by quaternion b
    float4 mulQ(float4 a, float4 b) {
        return float4( a.w*b.xyz + b.w*a.xyz + cross(a.xyz,b.xyz), a.w*b.w - dot(a.xyz,b.xyz));
    }
    float4 conjQ(float4 q) { return float4(-q.xyz, q.w); }
    static const float3x3 mIdentity = float3x3(1,0,0,0,1,0,0,0,1);

    float3 rotQ(float3 v, float4 q) { return v + 2.*cross(q.xyz,cross(q.xyz,v) + q.w*v); }
    float3x3 rot(float4 q) {
        float xx = q.x*q.x, yy = q.y*q.y, zz = q.z*q.z, ww = q.w*q.w;
        float xy = q.x*q.y, wz = q.w*q.z, xz = q.x*q.z, wy = q.w*q.y;
        float yz = q.y*q.z, wx = q.w*q.x;
        return float3x3(
            ww+xx-yy-zz, 2.*(xy-wz), 2.*(xz+wy),
            2.*(xy+wz), ww-xx+yy-zz, 2.*(yz-wx),
            2.*(xz-wy), 2.*(yz+wx), ww-xx-yy+zz
        );
    }

    // M_view = M_rot * M_trans
    float4x4 mView( float3x3 _m, float3 _e) {
        return float4x4(
            _m[0], -dot(_m[0],_e),
            _m[1], -dot(_m[1],_e),
            _m[2], -dot(_m[2],_e),
            0,0,0,1
        );
    }
    //float4x4 mView( float3 _r, float3 _e) { return mView(rotXYZ(_r), _e); }
    float4x4 mView( float4 _q, float3 _e) { return mView(rot(_q), _e); }
    //float4x4 mView( float3 _a, float _r, float3 _e) { return mView(rot(_a,_r), _e); }
    //reverse z-depth.
    float4x4 mProj() {
        float zF = 10;
        float zN = 0.001;
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
    float4 getEye() { return tex2Dfetch(sampEye, int2(1,0)); }

#ifndef ARCBALL // roll when holding MMB
    float4 updRot()
    {
        float4   q = getRot();
        float2   r = gPoint * gSizeR * 2. - 1.;
        float3   d = float3(gLMB*gDelta, gHand*gDelta.x) * gFrameTime * gMseSpeed * .0002;
        float3x3 m = rot(q);

        //float    l = length(d.xy);
        //if(l > 0) q = mulQ(q, quat(mul(float3(d.y,-d.x,0)/l,m), l)); // transform local normal to world normal.

        q = mulQ(q, quat(m[1],d.x));    // rotate about local y by dx
        q = mulQ(q, quat(m[0],d.y));    // rotate about local x by dy
        q = mulQ(q, quat(m[2],d.z));    // rotate about local z by dz
        return normalize(q);            // renormalize to reduce accumelative error
    }
    // rotate offset from view space to world space
    float4 updEye()
    {
        float3 eye = mul(float3(gRight - gLeft, 0, gForward - gBack), rot(updRot())) + float3(0,0, gUp - gDown);
        return float4(clamp(eye * gFrameTime * .001 * gMovSpeed + getEye().xyz, -10, 10),0);
    }
#else // arcball
    float4 updRot() {
        float3   d = float3(gLMB*gDelta, gHand*gDelta.x) * gFrameTime * gMseSpeed * .0002 * !gActive;
        float4   q = getRot();
        float3x3 m = rot(q);
        float2   l = float2(length(m[2].xy), length(m[0].xy));
        float3   n = l.y > 0.? float3(m[0].xy/l.y,0):float3(m[2].y,-m[2].x,0)/l.x;

        q = mulQ(q, quat(float3(0,0,1),d.x)); // rotate about world z by dx
        q = mulQ(q, quat(n,            d.y)); // rotate about normal by dy
        q = mulQ(q, quat(m[2],         d.z)); // rotate about local z by dz
        return normalize(q); // renormalize to reduce accumelative error
    }
    float4 updEye()
    {
        float3   s = float3(gRight - gLeft, gUp - gDown, gForward - gBack) * gFrameTime * .001 * gMovSpeed * !gActive;
        float4   e = getEye();
        float3x3 m = rot(updRot()); // x-axis, y-axis, z-axis
        float2   l = float2(length(m[2].xy), length(m[0].xy));
        float3   n = l.y > 0.? float3(m[0].xy/l.y,0):float3(m[2].y,-m[2].x,0)/l.x;
        float3   t = float3(n.y,-n.x,0);
        float    d = clamp(e.w + s.y, .01, 10);
        return float4(e.xyz + rot(getRot())[2]*e.w - m[2]*d + n*s.x + t*s.z, d); // move pivot point by wasd, dist by ctrl/space
        //return e;
    }
#endif
    float4 vs_ctrl( uint vid : SV_VERTEXID ) : SV_POSITION { return float4( vid*2.-1.,0, gOverlay? .5:-.5 ,1); }
    float4 ps_upd( float4 vpos : SV_POSITION ) : SV_TARGET { return vpos.x < 1.? updRot():updEye(); }
    float4 ps_eye( float4 vpos : SV_POSITION ) : SV_TARGET { return tex2Dfetch(sampUpd,vpos.xy); }
    float4 ps_init( float4 vpos : SV_POSITION ) : SV_TARGET { return vpos.x < 1.
        ? float4(sin(PI/2),0,0,cos(PI/2)) : float4(0,0,2,2);
    }

/******************************************************************
 *  transforms
 ******************************************************************/
    float4 transform(float4 p) { return mul(mProj(),mul(mView(getRot(),getEye().xyz),p)); }

    float trig( float t ) { return abs(frac(t) * 2. - 1.) * 2. - 1.; }

    uniform uint  gMode     <ui_type="radio"; ui_items="planer\0cylinder\0sphere\0wave\0";> = 0;
    uniform float gRadius   <ui_type="slider"; ui_min=.5;  ui_max=10;> = 3.;
    uniform float gWaveFreq <ui_type="slider"; ui_min=-5; ui_max=5; > = 1;
    uniform float gWaveLen  <ui_type="slider"; ui_min=.01;ui_max=5; > = .2;
    uniform float gWaveAmp  <ui_type="slider"; ui_min=-1; ui_max=1; > = .2;
    uniform float gDeform   <ui_type="slider"; ui_min=0; ui_max=1;  > = 0;

    #define PLANER      0
    #define CYLINDER    1
    #define SPHERE      2
    #define PERIODIC    3

    // input norm pos <- [1,-1]
    float4 posMod(float3 norm) {
        float4 pos;

        // without orientation change.
        // all surface shift to z=0;
        switch(gMode) {
            case PLANER :   pos.xyz = norm; break;
            case CYLINDER : pos.xyz = normalize(float3(norm.x,0,gRadius)) * (gRadius + norm.z) + float3(0, norm.y,-gRadius); break;
            case SPHERE :   pos.xyz = normalize(float3(norm.xy * gAspect.yx,gRadius)) * (gRadius + norm.z) / gAspect.yxy - float3(0,0,gRadius); break;
            case PERIODIC : {
                pos.xyz = norm.xyz;
                pos.w   = norm.x/gWaveLen + gTimer*.001*gWaveFreq;
                pos.z  += lerp(sin(pos.w * PI2), trig(pos.w), gDeform) * gWaveAmp * .1;
            } break;
        }
        pos.y  *= gAspect.x;
        pos.w   = 1;
        return pos; // output still around [1,-1]
    }
    // point generation
    float4 getPosP(uint vid, out float4 col, out float2 uv)
    {
        uv = (map2D(vid, POINTSEG) + .5) / float2(POINTSEG,POINTROW);

        col.rgb = tex2Dfetch(sampCol, uv * gSize).rgb;
        col.a   = 1; // no discarded point

        return posMod(float3( uv * 2. - 1, dot(col.rgb,.333) * gAmp));
    }
    // line generation
    float4 getPosL(uint vid, out float4 col, out float2 uv)
    {
        float2 lid = map2D(vid, LINESEG + 3); // lid.x <- [0, LINESEG + 2]

        uv.x    = saturate((lid.x - 1.) / LINESEG );
        uv.y    = lid.y / (LINEROW - 1);

        col.rgb = tex2Dfetch(sampCol, uv * gSize).rgb;
        col.a   = step(.5, lid.x) * step(lid.x, LINESEG + 1.5);

        return posMod(float3( uv * 2. - 1, dot(col.rgb,.333) * gAmp));
    }
    // trig generation
    float4 getPosT(uint vid, out float4 col, out float2 uv)
    {
        int2 tid = map2D(vid, (TRIGSEG + 2) * 2 ); // [0, (TRIGSEG + 2) * 2 - 1]
        int  id  = clamp(tid.x - 1,0, (TRIGSEG + 1) * 2 - 1);

        uv.x = float(id/2) / TRIGSEG;
        uv.y = (tid.y + float(id % 2)) / TRIGROW;

        col.rgb = tex2Dfetch(sampCol, uv * gSize).rgb;
        col.a   = step(.5, tid.x) * step(tid.x, (TRIGSEG + 1) * 2 + .5);

        return posMod(float3( uv * 2. - 1, dot(col.rgb,.333) * gAmp));
    }

/******************************************************************
 *  shaders
 ******************************************************************/

    // depth map
    float4 vs_pointD(uint vid : SV_VERTEXID, out float4 col : TEXCOORD) : SV_POSITION {
        float2 _; return transform(getPosP(vid, col, _));
    }
    float4 vs_point(uint vid : SV_VERTEXID, out float4 col : TEXCOORD) : SV_POSITION {
        float2 _; return transform(getPosP(vid, col, _));
    }
    float4 vs_lineD(uint vid : SV_VERTEXID, out float4 col : TEXCOORD) : SV_POSITION {
        float2 _; return transform(getPosL(vid, col, _));
    }
    float4 vs_line(uint vid : SV_VERTEXID, out float4 col : TEXCOORD) : SV_POSITION {
        float2 _; return transform(getPosL(vid, col, _));
    }
    float4 vs_trigD(uint vid : SV_VERTEXID, out float4 col : TEXCOORD) : SV_POSITION {
        float2 _; return transform(getPosT(vid, col, _));
    }
    float4 vs_trig(uint vid : SV_VERTEXID, out float4 col : TEXCOORD) : SV_POSITION {
        float2 _; return transform(getPosT(vid, col, _));
    }
    // per pixel depth test. would alpha blend faster then discard?
    float4 ps_draw( float4 vpos : SV_POSITION, float4 col : TEXCOORD0) : SV_TARGET {
        return col.a *= vpos.z >= tex2Dfetch(sampDep, vpos.xy).x, col;
    }
    // write screenspace z to depth buffer
    // SV_POSITION z component is screenspace z (clip.z / clip.w), w component is clipspace w (clip.w).
    float  ps_depth( float4 vpos : SV_POSITION, float4 col : TEXCOORD ) : SV_TARGET {
        if(col.a < .1) discard; else return vpos.z;
    }


    float gridline(float2 uv) {
        return any(abs(uv - trunc(uv)) < fwidth(uv));
    }
    // draw gridline (kinda work, but failed when out of)
    // float4 vs_grid( uint vid : SV_VERTEXID, out float2 uv : TEXCOORD ) : SV_POSITION {
    //     float3 p     = uint3(2,1,0) == vid ? float3(3,-3,1):float3(-1,1,1);     // view vector in clip space.
    //     float3 v     = normalize(p*float3(tan(radians(gFov*.5))/gAspect,1));    // view vector at corner in view space
    //     float3 w     = mul(v,rot(getRot()));                                    // view vector at corners in world space.
    //     float3 e     = getEye().xyz;        // eye pos at world space.
    //     float  r     = -e.z/w.z;            // linear depth along view vector in world space to z=0 plane.
    //            uv    = (e + w*r).xy * 5.;   // intersection point in world space on z=0 plane
    //     return mul(mProj(),float4(v*r,1));
    // }
    // float4 ps_grid( float4 vpos : SV_POSITION, float2 uv : TEXCOORD ) : SV_TARGET {
    //     bool2 d = abs(uv) < fwidth(uv);
    //     if(vpos.z >= tex2Dfetch(sampDep, vpos.xy).x)
    //         return any(d)? float4(d,0,1) : gridline(uv)*.5;
    //     discard;
    // }
    // float4 ps_grid_depth( float4 vpos : SV_POSITION, float2 uv : TEXCOORD ) : SV_TARGET {
    //     return vpos.z * gridline(uv);
    // }
    float4 vs_grid( uint vid : SV_VERTEXID, out float3 v : TEXCOORD ) : SV_POSITION {
        float4 p = uint4(2,1,0,0) == vid ? float4(3,-3,0,1):float4(-1,1,0,1);       // view vector in clip space.
        return v = p.xyw*float3(tan(radians(gFov*.5))/gAspect,1), p.xy *= gGrid, p; // view vector at corner in view space
    }
    float3 getGrid(float3 v) {
        v = normalize(v);
        float3 w = mul(v,rot(getRot()));                // view vector at corners in world space.
        float3 e = getEye().xyz;                        // eye pos at world space.
        float  r = -e.z/w.z;                            // linear depth along view vector in world space to z=0 plane.
        float2 d = mul(mProj(),float4(v*r,1)).zw;
        return float3((e + w*r).xy * 5., d.x/d.y);      // intersection point in world space on z=0 plane
    }
    float4 ps_grid( float4 vpos : SV_POSITION, float3 view : TEXCOORD ) : SV_TARGET {
        view = getGrid(view);
        bool2 d = abs(view.xy) < fwidth(view.xy);
        if(view.z >= tex2Dfetch(sampDep, vpos.xy).x)
            return any(d)? float4(d.yx,0,1) : gridline(view.xy)*.5;
        discard;
    }
    float4 ps_grid_depth( float4 vpos : SV_POSITION, float3 view : TEXCOORD ) : SV_TARGET {
        return view = getGrid(view), gridline(view.xy) * view.z;
    }

/******************************************************************
 *  technique
 ******************************************************************/

    technique synth_init < hidden=true; toggle=KEY_RESET; enabled=true; timeout=1;>
    {
        pass init {
            PrimitiveTopology   = LINELIST;
            VertexCount         = 2;
            VertexShader        = vs_ctrl;
            PixelShader         = ps_init;
            RenderTarget        = texEye;
        }
    }
    #define DEF_PASS_CTRL \
        upd { \
            PrimitiveTopology   = LINELIST; \
            VertexCount         = 2; \
            VertexShader        = vs_ctrl; \
            PixelShader         = ps_upd; \
            RenderTarget        = texUpd; \
        } \
        pass eye { \
            PrimitiveTopology   = LINELIST; \
            VertexCount         = 2; \
            VertexShader        = vs_ctrl; \
            PixelShader         = ps_eye; \
            RenderTarget        = texEye; \
        }
    #define DEF_PASS_GRIDLINE \
            depth { \
            VertexShader            = vs_grid; \
            PixelShader             = ps_grid_depth; \
            RenderTarget	        = texDep; \
            BlendEnable 	        = true; \
            BlendOp			        = Max; \
            DestBlend		        = ONE; \
        } \
        pass grid { \
            VertexShader            = vs_grid; \
            PixelShader             = ps_grid; \
            BlendEnable             = true; \
            SrcBlend                = SRCALPHA; \
            DestBlend               = INVSRCALPHA; \
            RenderTargetWriteMask   = 7; \
        }

    technique synth_point
    {
        pass DEF_PASS_CTRL

        pass depth {
            ClearRenderTargets      = true;
            VertexCount             = POINTSEG * POINTROW;
            PrimitiveTopology       = POINTLIST;
            VertexShader            = vs_pointD;
            PixelShader             = ps_depth;
            RenderTarget	        = texDep;
            BlendEnable 	        = true;
            BlendOp			        = Max;
            DestBlend		        = ONE;
        }
        pass points {
            ClearRenderTargets      = true;
            VertexCount             = POINTSEG * POINTROW;
            PrimitiveTopology       = POINTLIST;
            VertexShader            = vs_point;
            PixelShader             = ps_draw;
            BlendEnable             = true;
            SrcBlend                = SRCALPHA;
            DestBlend               = INVSRCALPHA;
            RenderTargetWriteMask   = 7;
        }

        pass DEF_PASS_GRIDLINE
    }
    technique synth_line
    {
        pass DEF_PASS_CTRL

        pass depth {
            ClearRenderTargets      = true;
            VertexCount             = (LINESEG + 3) * LINEROW;
            PrimitiveTopology       = LINESTRIP;
            VertexShader            = vs_lineD;
            PixelShader             = ps_depth;
            RenderTarget	        = texDep;
            BlendEnable 	        = true;
            BlendOp			        = Max;
            DestBlend		        = ONE;
        }
        pass lines {
            ClearRenderTargets      = true;
            VertexCount             = (LINESEG + 3) * LINEROW;
            PrimitiveTopology       = LINESTRIP;
            VertexShader            = vs_line;
            PixelShader             = ps_draw;
            BlendEnable             = true;
            SrcBlend                = SRCALPHA;
            DestBlend               = INVSRCALPHA;
            RenderTargetWriteMask   = 7;
        }

        pass DEF_PASS_GRIDLINE
    }
    technique synth_trig
    {
        pass DEF_PASS_CTRL

        pass depth {
            ClearRenderTargets      = true;
            VertexCount             = (TRIGSEG + 2) * 2 * TRIGROW;
            PrimitiveTopology       = TRIANGLESTRIP;
            VertexShader            = vs_trigD;
            PixelShader             = ps_depth;
            RenderTarget	        = texDep;
            BlendEnable 	        = true;
            BlendOp			        = Max;
            DestBlend		        = ONE;
        }
        pass trig {
            ClearRenderTargets      = true;
            VertexCount             = (TRIGSEG + 2) * 2 * TRIGROW;
            PrimitiveTopology       = TRIANGLESTRIP;
            VertexShader            = vs_trig;
            PixelShader             = ps_draw;
            BlendEnable             = true;
            SrcBlend                = SRCALPHA;
            DestBlend               = INVSRCALPHA;
            RenderTargetWriteMask   = 7;
        }

        pass DEF_PASS_GRIDLINE
    }
}
