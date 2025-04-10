#include <asm/asm_defns.h>
#include <asm/macros.h>
#include <asm/regs.h>
#include <asm/alternative.h>
#include <public/xen.h>

/*
 * Short-hands to defined the interrupts (A, I, F)
 *
 * _ means the interrupt state will not change
 * X means the state of interrupt X will change
 *
 * To be used with msr cpsr_* only
 */
#define IFLAGS_AIF      PSR_ABT_MASK | PSR_IRQ_MASK | PSR_FIQ_MASK
#define IFLAGS_A_F      PSR_ABT_MASK | PSR_FIQ_MASK

#define SAVE_ONE_BANKED(reg)    mrs r11, reg; str r11, [sp, #UREGS_##reg]
#define RESTORE_ONE_BANKED(reg) ldr r11, [sp, #UREGS_##reg]; msr reg, r11

#define SAVE_BANKED(mode) \
        SAVE_ONE_BANKED(SP_##mode) ; SAVE_ONE_BANKED(LR_##mode) ; SAVE_ONE_BANKED(SPSR_##mode)

#define RESTORE_BANKED(mode) \
        RESTORE_ONE_BANKED(SP_##mode) ; RESTORE_ONE_BANKED(LR_##mode) ; RESTORE_ONE_BANKED(SPSR_##mode)

save_guest_regs:
#ifdef CONFIG_ARM32_HARDEN_BRANCH_PREDICTOR
        /*
         * Restore vectors table to the default as it may have been
         * changed when returning to the guest (see
         * return_to_hypervisor). We need to do that early (e.g before
         * any interrupts are unmasked) because hardened vectors requires
         * SP to be 8 bytes aligned. This does not hold when running in
         * the hypervisor.
         */
        ldr r1, =hyp_traps_vector
        mcr p15, 4, r1, c12, c0, 0
        isb
#endif

        ldr r11, =0xffffffff  /* Clobber SP which is only valid for hypervisor frames. */
        str r11, [sp, #UREGS_sp]
        SAVE_ONE_BANKED(SP_usr)
        /* LR_usr is the same physical register as lr and is saved by the caller */
        SAVE_BANKED(svc)
        SAVE_BANKED(abt)
        SAVE_BANKED(und)
        SAVE_BANKED(irq)
        SAVE_BANKED(fiq)
        SAVE_ONE_BANKED(R8_fiq); SAVE_ONE_BANKED(R9_fiq); SAVE_ONE_BANKED(R10_fiq)
        SAVE_ONE_BANKED(R11_fiq); SAVE_ONE_BANKED(R12_fiq);

        /*
         * If the SKIP_SYNCHRONIZE_SERROR_ENTRY_EXIT has been set in the cpu
         * feature, the checking of pending SErrors will be skipped.
         */
        ALTERNATIVE("nop",
                    "b skip_check",
                    SKIP_SYNCHRONIZE_SERROR_ENTRY_EXIT)
        /*
         * Start to check pending virtual abort in the gap of Guest -> HYP
         * world switch.
         *
         * Save ELR_hyp to check whether the pending virtual abort exception
         * takes place while we are doing this trap exception.
         */
        mrs r1, ELR_hyp

        /*
         * Force loads and stores to complete before unmasking asynchronous
         * aborts and forcing the delivery of the exception.
         */
        dsb sy

        /*
         * Unmask asynchronous abort bit. If there is a pending asynchronous
         * abort, the data_abort exception will happen after A bit is cleared.
         */
        cpsie a

        /*
         * This is our single instruction exception window. A pending
         * asynchronous abort is guaranteed to occur at the earliest when we
         * unmask it, and at the latest just after the ISB.
         *
         * If a pending abort occurs, the program will jump to data_abort
         * exception handler, and the ELR_hyp will be set to
         * abort_guest_exit_start or abort_guest_exit_end.
         */
        .global abort_guest_exit_start
abort_guest_exit_start:

        isb

        .global abort_guest_exit_end
abort_guest_exit_end:
        /* Mask CPSR asynchronous abort bit, close the checking window. */
        cpsid a

        /*
         * Compare ELR_hyp and the saved value to check whether we are
         * returning from a valid exception caused by pending virtual
         * abort.
         */
        mrs r2, ELR_hyp
        cmp r1, r2

        /*
         * Not equal, the pending virtual abort exception took place, the
         * initial exception does not have any significance to be handled.
         * Exit ASAP.
         */
        bne return_from_trap

skip_check:
        mov pc, lr

        /*
         * Macro to define a trap entry.
         *
         *  @guest_iflags: Optional list of interrupts to unmask when
         *      entering from guest context. As this is used with cpsie,
         *      the letter (a, i, f) should be used.
         *
         *  @hyp_iflags: Optional list of interrupts to inherit when
         *      entering from hypervisor context. Any interrupts not
         *      listed will be kept unchanged. As this is used with cpsr_*,
         *      IFLAGS_* short-hands should be used.
         */
        .macro vector trap, guest_iflags=n, hyp_iflags=0
        /* Save registers in the stack */
        sub     sp, #(UREGS_SP_usr - UREGS_sp) /* SP, LR, SPSR, PC */
        push    {r0-r12}                       /* Save R0-R12 */
        mrs     r11, ELR_hyp                   /* ELR_hyp is return address */
        str     r11, [sp, #UREGS_pc]

        str     lr, [sp, #UREGS_lr]

        add     r11, sp, #(UREGS_kernel_sizeof + 4)

        str     r11, [sp, #UREGS_sp]

        mrc     CP32(r11, HSR)                 /* Save exception syndrome */
        str     r11, [sp, #UREGS_hsr]

        mrs     r11, SPSR_hyp
        str     r11, [sp, #UREGS_cpsr]

        /*
         * We need to distinguish whether we came from guest or
         * hypervisor context.
         */
        and     r0, r11, #PSR_MODE_MASK
        cmp     r0, #PSR_MODE_HYP

        bne     1f
        /*
         * Trap from the hypervisor
         *
         * Inherit the state of the interrupts from the hypervisor
         * context. For that we need to use SPSR (stored in r11) and
         * modify CPSR accordingly.
         *
         * CPSR = (CPSR & ~hyp_iflags) | (SPSR & hyp_iflags)
         */
        mrs     r10, cpsr
        bic     r10, r10, #\hyp_iflags
        and     r11, r11, #\hyp_iflags
        orr     r10, r10, r11
        msr     cpsr_cx, r10
        b       2f

1:
        /* Trap from the guest */
        bl      save_guest_regs
        .if     \guest_iflags != n
        cpsie   \guest_iflags
        .endif
2:
        /* We are ready to handle the trap, setup the registers and jump. */
        adr     lr, return_from_trap
        mov     r0, sp
        /*
         * Save the stack pointer in r11. It will be restored after the
         * trap has been handled (see return_from_trap).
         */
        mov     r11, sp
        bic     sp, #7      /* Align the stack pointer (noop on guest trap) */
        b       do_trap_\trap
        .endm

        .align 5
GLOBAL(hyp_traps_vector)
        b trap_reset                    /* 0x00 - Reset */
        b trap_undefined_instruction    /* 0x04 - Undefined Instruction */
        b trap_hypervisor_call          /* 0x08 - Hypervisor Call */
        b trap_prefetch_abort           /* 0x0c - Prefetch Abort */
        b trap_data_abort               /* 0x10 - Data Abort */
        b trap_guest_sync               /* 0x14 - Hypervisor */
        b trap_irq                      /* 0x18 - IRQ */
        b trap_fiq                      /* 0x1c - FIQ */

#ifdef CONFIG_HARDEN_BRANCH_PREDICTOR

        .align 5
GLOBAL(hyp_traps_vector_ic_inv)
        /*
         * We encode the exception entry in the bottom 3 bits of
         * SP, and we have to guarantee to be 8 bytes aligned.
         */
        add sp, sp, #1                  /* Reset            7 */
        add sp, sp, #1                  /* Undef            6 */
        add sp, sp, #1                  /* Hypervisor call  5 */
        add sp, sp, #1                  /* Prefetch abort   4 */
        add sp, sp, #1                  /* Data abort       3 */
        add sp, sp, #1                  /* Hypervisor       2 */
        add sp, sp, #1                  /* IRQ              1 */
        nop                             /* FIQ              0 */

        mcr p15, 0, r0, c7, c5, 0       /* ICIALLU */
        isb

        b decode_vectors

        .align 5
GLOBAL(hyp_traps_vector_bp_inv)
        /*
         * We encode the exception entry in the bottom 3 bits of
         * SP, and we have to guarantee to be 8 bytes aligned.
         */
        add sp, sp, #1                  /* Reset            7 */
        add sp, sp, #1                  /* Undef            6 */
        add sp, sp, #1                  /* Hypervisor Call  5 */
        add sp, sp, #1                  /* Prefetch abort   4 */
        add sp, sp, #1                  /* Data abort       3 */
        add sp, sp, #1                  /* Hypervisor       2 */
        add sp, sp, #1                  /* IRQ              1 */
        nop                             /* FIQ              0 */

        mcr	p15, 0, r0, c7, c5, 6	    /* BPIALL */
        isb

decode_vectors:
.macro vect_br val, targ
        eor     sp, sp, #\val
        tst     sp, #7
        eorne   sp, sp, #\val
        beq     \targ
.endm

        vect_br 0, trap_fiq
        vect_br 1, trap_irq
        vect_br 2, trap_guest_sync
        vect_br 3, trap_data_abort
        vect_br 4, trap_prefetch_abort
        vect_br 5, trap_hypervisor_call
        vect_br 6, trap_undefined_instruction
        vect_br 7, trap_reset

#endif /* CONFIG_HARDEN_BRANCH_PREDICTOR */

/* Vector not used by the Hypervisor. */
trap_reset:
        vector reset

/*
 * Vector only used by the Hypervisor.
 *
 * While the exception can be executed with all the interrupts (e.g.
 * IRQ) unmasked, the interrupted context may have purposefully masked
 * some of them. So we want to inherit the state from the interrupted
 * context.
 */
trap_undefined_instruction:
        vector undefined_instruction, hyp_iflags=IFLAGS_AIF

/* We should never reach this trap */
trap_hypervisor_call:
        vector hypervisor_call

/*
 * Vector only used by the hypervisor.
 *
 * While the exception can be executed with all the interrupts (e.g.
 * IRQ) unmasked, the interrupted context may have purposefully masked
 * some of them. So we want to inherit the state from the interrupted
 * context.
 */
trap_prefetch_abort:
       vector prefetch_abort, hyp_iflags=IFLAGS_AIF

/*
 * Vector only used by the hypervisor.
 *
 * Data Abort should be rare and most likely fatal. It is best to not
 * unmask any interrupts to limit the amount of code that can run before
 * the Data Abort is treated.
 */
trap_data_abort:
        vector data_abort

/* Vector only used by the guest. We can unmask Abort/IRQ. */
trap_guest_sync:
        vector guest_sync, guest_iflags=ai


/* Vector used by the hypervisor and the guest. */
trap_irq:
        vector irq, guest_iflags=a, hyp_iflags=IFLAGS_A_F

/*
 * Vector used by the hypervisor and the guest.
 *
 * FIQ are not meant to happen, so we don't unmask any interrupts.
 */
trap_fiq:
        vector fiq

return_from_trap:
        /*
         * Restore the stack pointer from r11. It was saved on exception
         * entry (see __DEFINE_TRAP_ENTRY).
         */
        mov sp, r11
ENTRY(return_to_new_vcpu32)
        ldr r11, [sp, #UREGS_cpsr]
        and r11, #PSR_MODE_MASK
        cmp r11, #PSR_MODE_HYP
        beq return_to_hypervisor
        /* Fall thru */
return_to_guest:
        mov r11, sp
        bic sp, #7 /* Align the stack pointer */
        bl leave_hypervisor_tail /* Disables interrupts on return */
        mov sp, r11
        RESTORE_ONE_BANKED(SP_usr)
        /* LR_usr is the same physical register as lr and is restored below */
        RESTORE_BANKED(svc)
        RESTORE_BANKED(abt)
        RESTORE_BANKED(und)
        RESTORE_BANKED(irq)
        RESTORE_BANKED(fiq)
        RESTORE_ONE_BANKED(R8_fiq); RESTORE_ONE_BANKED(R9_fiq); RESTORE_ONE_BANKED(R10_fiq)
        RESTORE_ONE_BANKED(R11_fiq); RESTORE_ONE_BANKED(R12_fiq);
        /* Fall thru */
return_to_hypervisor:
        cpsid ai
        ldr lr, [sp, #UREGS_lr]
        ldr r11, [sp, #UREGS_pc]
        msr ELR_hyp, r11
        ldr r11, [sp, #UREGS_cpsr]
        msr SPSR_hyp, r11
#ifdef CONFIG_ARM32_HARDEN_BRANCH_PREDICTOR
        /*
         * Hardening branch predictor may require to setup a different
         * vector tables before returning to the guests. Those vectors
         * may rely on the state of registers that does not hold when
         * running in the hypervisor (e.g SP is 8 bytes aligned). So setup
         * HVBAR very late.
         *
         * Default vectors table will be restored on exit (see
         * save_guest_regs).
         */
        mov r9, #0                      /* vector tables = NULL */
        /*
         * Load vector tables pointer from the per-cpu bp_harden_vecs
         * when returning to the guest only.
         */
        and r11, #PSR_MODE_MASK
        cmp r11, #PSR_MODE_HYP
        ldrne r11, =per_cpu__bp_harden_vecs
        mrcne p15, 4, r10, c13, c0, 2   /* r10 = per-cpu offset (HTPIDR) */
        addne r11, r11, r10             /* r11 = offset of the vector tables */
        ldrne r9, [r11]                 /* r9  = vector tables */
        cmp r9, #0                      /* Only update HVBAR when the vector */
        mcrne p15, 4, r9, c12, c0, 0    /* tables is not NULL. */
#endif
        pop {r0-r12}
        add sp, #(UREGS_SP_usr - UREGS_sp); /* SP, LR, SPSR, PC */
        clrex
        eret
        sb

/*
 * struct vcpu *__context_switch(struct vcpu *prev, struct vcpu *next)
 *
 * r0 - prev
 * r1 - next
 *
 * Returns prev in r0
 */
ENTRY(__context_switch)
        add     ip, r0, #VCPU_arch_saved_context
        stmia   ip!, {r4 - sl, fp, sp, lr}      /* Save register state */

        add     r4, r1, #VCPU_arch_saved_context
        ldmia   r4, {r4 - sl, fp, sp, pc}       /* Load registers and return */

/*
 * Local variables:
 * mode: ASM
 * indent-tabs-mode: nil
 * End:
 */
