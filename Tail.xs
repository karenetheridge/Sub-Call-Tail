/* ex: set sw=4 et: */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define NEED_sv_2pv_flags
#include "ppport.h"

#include "hook_op_check_entersubforcv.h"



STATIC OP *
goto_entersub (pTHX) {
    dVAR; dSP; dMARK; dPOPss;
    GV *gv;
    CV *cv;
    AV *av;
    I32 items = SP - MARK;
    int reify = 0;

    /* this first steaming hunk of cargo cult is copypasted from entersub...
     * it's pretty the original but the ENTER/LEAVE or the actual execution */

    if (!sv)
        DIE(aTHX_ "Not a CODE reference");    
    switch (SvTYPE(sv)) {
        /* This is overwhelming the most common case:  */
        case SVt_PVGV:
            if (!isGV_with_GP(sv))
                DIE(aTHX_ "Not a CODE reference");
            if (!(cv = GvCVu((const GV *)sv))) {
                HV *stash;
                cv = sv_2cv(sv, &stash, &gv, 0);
            }
            if (!cv) {
                goto try_autoload;
            }
            break;
        default:
            if (!SvROK(sv)) {
                const char *sym;
                STRLEN len;
                if (SvGMAGICAL(sv)) {
                    mg_get(sv);
                    if (SvROK(sv))
                        goto got_rv;
                    if (SvPOKp(sv)) {
                        sym = SvPVX_const(sv);
                        len = SvCUR(sv);
                    } else {
                        sym = NULL;
                        len = 0;
                    }
                }
                else {
                    sym = SvPV_const(sv, len);
                }
                if (!sym)
                    DIE(aTHX_ PL_no_usym, "a subroutine");
                if (PL_op->op_private & HINT_STRICT_REFS)
                    DIE(aTHX_ PL_no_symref, sym, "a subroutine");
                cv = get_cvn_flags(sym, len, GV_ADD|SvUTF8(sv));
                break;
            }
got_rv:
            {
                SV * const * sp = &sv;		/* Used in tryAMAGICunDEREF macro. */
                tryAMAGICunDEREF(to_cv);
            }	
            cv = MUTABLE_CV(SvRV(sv));
            if (SvTYPE(cv) == SVt_PVCV)
                break;
            /* FALL THROUGH */
        case SVt_PVHV:
        case SVt_PVAV:
            DIE(aTHX_ "Not a CODE reference");
            /* This is the second most common case:  */
        case SVt_PVCV:
            cv = MUTABLE_CV(sv);
            break;
    }

retry:
    if (!CvROOT(cv) && !CvXSUB(cv)) {
        GV* autogv;
        SV* sub_name;

        /* anonymous or undef'd function leaves us no recourse */
        if (CvANON(cv) || !(gv = CvGV(cv)))
            DIE(aTHX_ "Undefined subroutine called");

        /* autoloaded stub? */
        if (cv != GvCV(gv)) {
            cv = GvCV(gv);
        }
        /* should call AUTOLOAD now? */
        else {
try_autoload:
            if ((autogv = gv_autoload4(GvSTASH(gv), GvNAME(gv), GvNAMELEN(gv),
                            FALSE)))
            {
                cv = GvCV(autogv);
            }
            /* sorry */
            else {
                sub_name = sv_newmortal();
                gv_efullname3(sub_name, gv, NULL);
                DIE(aTHX_ "Undefined subroutine &%"SVf" called", SVfARG(sub_name));
            }
        }
        if (!cv)
            DIE(aTHX_ "Not a CODE reference");
        goto retry;
    }


    /* this next steaming hunk of cargo cult is the code that sets up @_ in
     * entersub. We set it up so that defgv is pointing at the pushed args as
     * set up by the entersub call, this will let pp_goto work unmodified */

    av = GvAV(PL_defgv);

    /* abandon @_ if it got reified */
    if (AvREAL(av)) {
        SvREFCNT_dec(av);
        av = newAV();
        av_extend(av, items-1);
        AvREIFY_only(av);
        PAD_SVl(0) = MUTABLE_SV( GvAV(PL_defgv) = av );
    }

    /* copy items from the stack to defgv */
    ++MARK;

    if (items > AvMAX(av) + 1) {
        SV **ary = AvALLOC(av);
        if (AvARRAY(av) != ary) {
            AvMAX(av) += AvARRAY(av) - AvALLOC(av);
            AvARRAY(av) = ary;
        }
        if (items > AvMAX(av) + 1) {
            AvMAX(av) = items - 1;
            Renew(ary,items,SV*);
            AvALLOC(av) = ary;
            AvARRAY(av) = ary;
        }
    }

    Copy(MARK,AvARRAY(av),items,SV*);
    AvFILLp(av) = items - 1;

    while (MARK <= SP) {
        if (*MARK) {
            SvTEMP_off(*MARK);

            /* if we find a PADMY it's probably from the scope being destroyed,
             * so we should reify @_ to increase the refcnt */
            if SvPADMY(*MARK) reify++;
        }
        MARK++;
    }


    if ( reify ) {
        I32 key;

        key = AvMAX(av) + 1;
        while (key > AvFILLp(av) + 1)
            AvARRAY(av)[--key] = &PL_sv_undef;
        while (key) {
            SV * const sv = AvARRAY(av)[--key];
            assert(sv);
            if (sv != &PL_sv_undef)
                SvREFCNT_inc_simple_void_NN(sv);
        }
        key = AvARRAY(av) - AvALLOC(av);
        while (key)
            AvALLOC(av)[--key] = &PL_sv_undef;
        AvREIFY_off(av);
        AvREAL_on(av);
    }

    SP -= items;

    /* finally, execute goto. goto uses a ref to the cv, and takes the args out
     * of defgv */

    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newRV_inc((SV *)cv)));
    PUTBACK;

    return PL_ppaddr[OP_GOTO](aTHX);
}

STATIC OP *
convert_to_tailcall (pTHX_ OP *o, CV *cv, void *user_data) {
    /* find the nested entersub */
    UNOP *entersub = (UNOP *)((LISTOP *)cUNOPo->op_first)->op_first->op_sibling;

    if ( !(entersub->op_flags & OPf_STACKED) ) {
        croak("Tail call must have arguments");
    }

    /* change the ppaddr of the inner entersub to become a goto */
    entersub->op_ppaddr = goto_entersub;

    /* the rest is unmodified, this code will not actually be run (except for
     * the pushmark), but allows deparsing etc to work correctly */
    return o;
}

MODULE = Sub::Call::Tail	PACKAGE = Sub::Call::Tail
PROTOTYPES: disable

BOOT:
{
    hook_op_check_entersubforcv(get_cv("Sub::Call::Tail::tail", TRUE), convert_to_tailcall, NULL);
}
