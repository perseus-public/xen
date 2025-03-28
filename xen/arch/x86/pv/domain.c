/******************************************************************************
 * arch/x86/pv/domain.c
 *
 * PV domain handling
 */

#include <xen/domain_page.h>
#include <xen/errno.h>
#include <xen/lib.h>
#include <xen/sched.h>

#include <asm/cpufeature.h>
#include <asm/invpcid.h>
#include <asm/spec_ctrl.h>
#include <asm/pv/domain.h>
#include <asm/shadow.h>

static __read_mostly enum {
    PCID_OFF,
    PCID_ALL,
    PCID_XPTI,
    PCID_NOXPTI
} opt_pcid = PCID_XPTI;

static int parse_pcid(const char *s)
{
    int rc = 0;

    switch ( parse_bool(s, NULL) )
    {
    case 0:
        opt_pcid = PCID_OFF;
        break;

    case 1:
        opt_pcid = PCID_ALL;
        break;

    default:
        switch ( parse_boolean("xpti", s, NULL) )
        {
        case 0:
            opt_pcid = PCID_NOXPTI;
            break;

        case 1:
            opt_pcid = PCID_XPTI;
            break;

        default:
            rc = -EINVAL;
            break;
        }
        break;
    }

    return rc;
}
custom_runtime_param("pcid", parse_pcid);

/* Override macros from asm/page.h to make them work with mfn_t */
#undef mfn_to_page
#define mfn_to_page(mfn) __mfn_to_page(mfn_x(mfn))
#undef page_to_mfn
#define page_to_mfn(pg) _mfn(__page_to_mfn(pg))

static void noreturn continue_nonidle_domain(void)
{
    check_wakeup_from_wait();
    reset_stack_and_jump(ret_from_intr);
}

static int setup_compat_l4(struct vcpu *v)
{
    struct page_info *pg;
    l4_pgentry_t *l4tab;
    mfn_t mfn;

    pg = alloc_domheap_page(v->domain, MEMF_no_owner | MEMF_no_scrub);
    if ( pg == NULL )
        return -ENOMEM;

    mfn = page_to_mfn(pg);
    l4tab = map_domain_page(mfn);
    clear_page(l4tab);
    init_xen_l4_slots(l4tab, mfn, v->domain, INVALID_MFN, false);
    unmap_domain_page(l4tab);

    /* This page needs to look like a pagetable so that it can be shadowed */
    pg->u.inuse.type_info = PGT_l4_page_table | PGT_validated | 1;

    v->arch.guest_table = pagetable_from_page(pg);
    v->arch.guest_table_user = v->arch.guest_table;

    return 0;
}

static void release_compat_l4(struct vcpu *v)
{
    if ( !pagetable_is_null(v->arch.guest_table) )
        free_domheap_page(pagetable_get_page(v->arch.guest_table));
    v->arch.guest_table = pagetable_null();
    v->arch.guest_table_user = pagetable_null();
}

unsigned long pv_fixup_guest_cr4(const struct vcpu *v, unsigned long cr4)
{
    const struct cpuid_policy *p = v->domain->arch.cpuid;

    /* Discard attempts to set guest controllable bits outside of the policy. */
    cr4 &= ~((p->basic.tsc     ? 0 : X86_CR4_TSD)      |
             (p->basic.de      ? 0 : X86_CR4_DE)       |
             (p->feat.fsgsbase ? 0 : X86_CR4_FSGSBASE) |
             (p->basic.xsave   ? 0 : X86_CR4_OSXSAVE));

    /* Masks expected to be disjoint sets. */
    BUILD_BUG_ON(PV_CR4_GUEST_MASK & PV_CR4_GUEST_VISIBLE_MASK);

    /*
     * A guest sees the policy subset of its own choice of guest controllable
     * bits, and a subset of Xen's choice of certain hardware settings.
     */
    return ((cr4 & PV_CR4_GUEST_MASK) |
            (mmu_cr4_features & PV_CR4_GUEST_VISIBLE_MASK));
}

unsigned long pv_make_cr4(const struct vcpu *v)
{
    const struct domain *d = v->domain;
    unsigned long cr4 = mmu_cr4_features &
        ~(X86_CR4_PCIDE | X86_CR4_PGE | X86_CR4_TSD);

    /*
     * PCIDE or PGE depends on the PCID/XPTI settings, but must not both be
     * set, as it impacts the safety of TLB flushing.
     */
    if ( d->arch.pv_domain.pcid )
        cr4 |= X86_CR4_PCIDE;
    else if ( !d->arch.pv_domain.xpti )
        cr4 |= X86_CR4_PGE;

    /*
     * TSD is needed if either the guest has elected to use it, or Xen is
     * virtualising the TSC value the guest sees.
     */
    if ( d->arch.vtsc || (v->arch.pv_vcpu.ctrlreg[4] & X86_CR4_TSD) )
        cr4 |= X86_CR4_TSD;

    /*
     * The {RD,WR}{FS,GS}BASE are only useable in 64bit code segments.  While
     * we must not have CR4.FSGSBASE set behind the back of a 64bit PV kernel,
     * we do leave it set in 32bit PV context to speed up Xen's context switch
     * path.
     */
    if ( !is_pv_32bit_domain(d) &&
         !(v->arch.pv_vcpu.ctrlreg[4] & X86_CR4_FSGSBASE) )
        cr4 &= ~X86_CR4_FSGSBASE;

    return cr4;
}

int switch_compat(struct domain *d)
{
    struct vcpu *v;
    int rc;

    BUILD_BUG_ON(offsetof(struct shared_info, vcpu_info) != 0);

    if ( is_hvm_domain(d) || d->tot_pages != 0 )
        return -EACCES;
    if ( is_pv_32bit_domain(d) )
        return 0;

    d->arch.has_32bit_shinfo = 1;
    d->arch.is_32bit_pv = 1;

    for_each_vcpu( d, v )
    {
        if ( (rc = setup_compat_arg_xlat(v)) ||
             (rc = setup_compat_l4(v)) )
            goto undo_and_fail;
    }

    domain_set_alloc_bitsize(d);
    recalculate_cpuid_policy(d);

    d->arch.x87_fip_width = 4;

    d->arch.pv_domain.xpti = false;
    d->arch.pv_domain.pcid = false;

    return 0;

 undo_and_fail:
    d->arch.is_32bit_pv = d->arch.has_32bit_shinfo = 0;
    for_each_vcpu( d, v )
    {
        free_compat_arg_xlat(v);
        release_compat_l4(v);
    }

    return rc;
}

static int pv_create_gdt_ldt_l1tab(struct vcpu *v)
{
    return create_perdomain_mapping(v->domain, GDT_VIRT_START(v),
                                    1U << GDT_LDT_VCPU_SHIFT,
                                    v->domain->arch.pv_domain.gdt_ldt_l1tab,
                                    NULL);
}

static void pv_destroy_gdt_ldt_l1tab(struct vcpu *v)
{
    destroy_perdomain_mapping(v->domain, GDT_VIRT_START(v),
                              1U << GDT_LDT_VCPU_SHIFT);
}

void pv_vcpu_destroy(struct vcpu *v)
{
    if ( is_pv_32bit_vcpu(v) )
    {
        free_compat_arg_xlat(v);
        release_compat_l4(v);
    }

    pv_destroy_gdt_ldt_l1tab(v);
    xfree(v->arch.pv_vcpu.trap_ctxt);
    v->arch.pv_vcpu.trap_ctxt = NULL;
}

int pv_vcpu_initialise(struct vcpu *v)
{
    struct domain *d = v->domain;
    int rc;

    ASSERT(!is_idle_domain(d));

    spin_lock_init(&v->arch.pv_vcpu.shadow_ldt_lock);

    rc = pv_create_gdt_ldt_l1tab(v);
    if ( rc )
        return rc;

    BUILD_BUG_ON(NR_VECTORS * sizeof(*v->arch.pv_vcpu.trap_ctxt) >
                 PAGE_SIZE);
    v->arch.pv_vcpu.trap_ctxt = xzalloc_array(struct trap_info,
                                              NR_VECTORS);
    if ( !v->arch.pv_vcpu.trap_ctxt )
    {
        rc = -ENOMEM;
        goto done;
    }

    /* PV guests by default have a 100Hz ticker. */
    v->periodic_period = MILLISECS(10);

    v->arch.pv_vcpu.ctrlreg[4] = pv_fixup_guest_cr4(v, 0);

    if ( is_pv_32bit_domain(d) )
    {
        if ( (rc = setup_compat_arg_xlat(v)) )
            goto done;

        if ( (rc = setup_compat_l4(v)) )
            goto done;
    }

 done:
    if ( rc )
        pv_vcpu_destroy(v);
    return rc;
}

void pv_domain_destroy(struct domain *d)
{
    pv_l1tf_domain_destroy(d);

    destroy_perdomain_mapping(d, GDT_LDT_VIRT_START,
                              GDT_LDT_MBYTES << (20 - PAGE_SHIFT));

    xfree(d->arch.pv_domain.cpuidmasks);
    d->arch.pv_domain.cpuidmasks = NULL;

    free_xenheap_page(d->arch.pv_domain.gdt_ldt_l1tab);
    d->arch.pv_domain.gdt_ldt_l1tab = NULL;
}


int pv_domain_initialise(struct domain *d, unsigned int domcr_flags,
                         struct xen_arch_domainconfig *config)
{
    static const struct arch_csw pv_csw = {
        .from = paravirt_ctxt_switch_from,
        .to   = paravirt_ctxt_switch_to,
        .tail = continue_nonidle_domain,
    };
    int rc = -ENOMEM;

    pv_l1tf_domain_init(d);

    d->arch.pv_domain.gdt_ldt_l1tab =
        alloc_xenheap_pages(0, MEMF_node(domain_to_node(d)));
    if ( !d->arch.pv_domain.gdt_ldt_l1tab )
        goto fail;
    clear_page(d->arch.pv_domain.gdt_ldt_l1tab);

    if ( levelling_caps & ~LCAP_faulting )
    {
        d->arch.pv_domain.cpuidmasks = xmalloc(struct cpuidmasks);
        if ( !d->arch.pv_domain.cpuidmasks )
            goto fail;
        *d->arch.pv_domain.cpuidmasks = cpuidmask_defaults;
    }

    rc = create_perdomain_mapping(d, GDT_LDT_VIRT_START,
                                  GDT_LDT_MBYTES << (20 - PAGE_SHIFT),
                                  NULL, NULL);
    if ( rc )
        goto fail;

    d->arch.ctxt_switch = &pv_csw;

    /* 64-bit PV guest by default. */
    d->arch.is_32bit_pv = d->arch.has_32bit_shinfo = 0;

    d->arch.pv_domain.xpti = is_hardware_domain(d) ? opt_xpti_hwdom
                                                   : opt_xpti_domu;

    if ( !is_pv_32bit_domain(d) && use_invpcid && cpu_has_pcid )
        switch ( opt_pcid )
        {
        case PCID_OFF:
            break;

        case PCID_ALL:
            d->arch.pv_domain.pcid = true;
            break;

        case PCID_XPTI:
            d->arch.pv_domain.pcid = d->arch.pv_domain.xpti;
            break;

        case PCID_NOXPTI:
            d->arch.pv_domain.pcid = !d->arch.pv_domain.xpti;
            break;

        default:
            ASSERT_UNREACHABLE();
            break;
        }

    return 0;

  fail:
    pv_domain_destroy(d);

    return rc;
}

void toggle_guest_mode(struct vcpu *v)
{
    if ( is_pv_32bit_vcpu(v) )
        return;

    /* %fs/%gs bases can only be stale if WR{FS,GS}BASE are usable. */
    if ( read_cr4() & X86_CR4_FSGSBASE )
    {
        if ( v->arch.flags & TF_kernel_mode )
            v->arch.pv_vcpu.gs_base_kernel = __rdgsbase();
        else
            v->arch.pv_vcpu.gs_base_user = __rdgsbase();
    }
    asm volatile ( "swapgs" );

    toggle_guest_pt(v);
}

void toggle_guest_pt(struct vcpu *v)
{
    const struct domain *d = v->domain;
    struct cpu_info *cpu_info = get_cpu_info();
    unsigned long cr3;

    if ( is_pv_32bit_vcpu(v) )
        return;

    v->arch.flags ^= TF_kernel_mode;
    update_cr3(v);
    if ( d->arch.pv_domain.xpti )
    {
        cpu_info->root_pgt_changed = true;
        cpu_info->pv_cr3 = __pa(this_cpu(root_pgt)) |
                           (d->arch.pv_domain.pcid
                            ? get_pcid_bits(v, true) : 0);
    }

    /*
     * Don't flush user global mappings from the TLB. Don't tick TLB clock.
     *
     * In shadow mode, though, update_cr3() may need to be accompanied by a
     * TLB flush (for just the incoming PCID), as the top level page table may
     * have changed behind our backs. To be on the safe side, suppress the
     * no-flush unconditionally in this case. The XPTI CR3 write, if enabled,
     * will then need to be a flushing one too.
     */
    cr3 = v->arch.cr3;
    if ( shadow_mode_enabled(d) )
    {
        cr3 &= ~X86_CR3_NOFLUSH;
        cpu_info->pv_cr3 &= ~X86_CR3_NOFLUSH;
    }
    write_cr3(cr3);

    if ( !(v->arch.flags & TF_kernel_mode) )
        return;

    if ( v->arch.pv_vcpu.need_update_runstate_area &&
         update_runstate_area(v) )
        v->arch.pv_vcpu.need_update_runstate_area = 0;

    if ( v->arch.pv_vcpu.pending_system_time.version &&
         update_secondary_system_time(v,
                                      &v->arch.pv_vcpu.pending_system_time) )
        v->arch.pv_vcpu.pending_system_time.version = 0;
}

/*
 * Local variables:
 * mode: C
 * c-file-style: "BSD"
 * c-basic-offset: 4
 * tab-width: 4
 * indent-tabs-mode: nil
 * End:
 */
