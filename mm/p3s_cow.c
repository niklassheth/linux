// SPDX-License-Identifier: GPL-2.0
/*
 * Copy-on-write into a sibling folio in 4KB compatibility VMAs.
 *
 * A write fault that copies a private file page or the zero page in a 4KB VMA
 * would allocate a 16KB folio for one 4KB slice, so a window whose slices are
 * copied one by one ends up on four folios. Instead, when another slice of the
 * same 16KB window is already backed by an anonymous folio that only this
 * window maps, copy into that folio's free slot for the faulting slice.
 */

#include <linux/highmem.h>
#include <linux/ksm.h>
#include <linux/mm.h>
#include <linux/mmu_notifier.h>
#include <linux/rmap.h>
#include <linux/swap.h>
#include <linux/userfaultfd_k.h>

#include <asm/cacheflush.h>
#include "internal.h"

static bool p3s_cow_vma_ok(struct vm_area_struct *vma, struct vm_fault *vmf)
{
	return vma_is_p3s_4k(vma) && !userfaultfd_armed(vma) &&
	       !(vma->vm_flags & (VM_MTE | VM_SHARED)) &&
	       !(vmf->flags & FAULT_FLAG_UNSHARE);
}

/*
 * The anonymous folio of a slice PTE in the window, if it can take another
 * slice: small, not KSM, not in the swap cache, exclusive to this mm, every
 * mapping of it a PTE in this window, and no reference beyond those mappings
 * (no GUP pin, no pending zap, not isolated). Its free slots then hold
 * nothing anyone can see.
 */
static struct folio *p3s_cow_sibling(struct vm_area_struct *vma, pte_t *pte_base,
				     unsigned long start, unsigned int nr_slices,
				     unsigned long addr, bool strict)
{
	unsigned int i;

	for (i = 0; i < nr_slices; i++) {
		unsigned long saddr = start + ((unsigned long)i << PAGE_SHIFT_4KB);
		pte_t ptent = ptep_get(pte_base + i);
		struct folio *folio;
		struct page *page;
		unsigned int mapped;

		if (saddr == addr || !pte_present(ptent))
			continue;
		page = vm_normal_page(vma, saddr, ptent);
		folio = page ? page_folio(page) : NULL;
		if (!folio || !folio_test_anon(folio) || folio_test_large(folio) ||
		    folio_test_ksm(folio) || folio_test_swapcache(folio) ||
		    !PageAnonExclusive(&folio->page))
			continue;
		if (!strict)
			return folio;
		mapped = p3s_count_folio_slices(vma, pte_base, start, nr_slices, folio);
		if (mapped != folio_mapcount(folio))
			continue;
		if (folio_ref_count(folio) != mapped && !folio_test_lru(folio))
			lru_add_drain();
		if (folio_ref_count(folio) != mapped)
			continue;
		return folio;
	}
	return NULL;
}

/**
 * p3s_wp_copy_into_sibling - COW a non-anonymous slice into a sibling folio
 * @vmf: Write fault on a present read-only PTE (wp_page_copy())
 * @old_folio: The page cache folio it maps, or NULL for the zero page
 *
 * Returns true if the fault was handled: the PTE now maps a copy of its 4KB in
 * the slot of a sibling anonymous folio, and the PTE's reference to
 * @old_folio is dropped (the caller still owns its own). Returns false to
 * let the caller allocate a new folio.
 */
bool p3s_wp_copy_into_sibling(struct vm_fault *vmf, struct folio *old_folio)
{
	struct vm_area_struct *vma = vmf->vma;
	struct mm_struct *mm = vma->vm_mm;
	unsigned long addr = vmf->address & PAGE_MASK_4KB;
	struct mmu_notifier_range range;
	unsigned int nr_slices, slot;
	unsigned long start;
	struct folio *folio;
	bool done = false;
	pte_t *pte_base;
	void *to;
	pte_t entry;

	if (!p3s_cow_vma_ok(vma, vmf) || (old_folio && folio_test_anon(old_folio)))
		return false;
	vma_folio_slice_bounds(vma, addr, &nr_slices, &start);
	if (nr_slices < 2)
		return false;

	mmu_notifier_range_init(&range, MMU_NOTIFY_CLEAR, 0, mm, addr,
				addr + PAGE_SIZE_4KB);
	mmu_notifier_invalidate_range_start(&range);
	vmf->pte = pte_offset_map_lock(mm, vmf->pmd, addr, &vmf->ptl);
	if (!vmf->pte)
		goto out;
	if (!pte_same(ptep_get(vmf->pte), vmf->orig_pte))
		goto unlock;
	pte_base = vmf->pte - ((addr - start) >> PAGE_SHIFT_4KB);
	folio = p3s_cow_sibling(vma, pte_base, start, nr_slices, addr, true);
	if (!folio)
		goto unlock;

	slot = vma_slice_offset(vma, addr);
	to = kmap_local_folio(folio, (size_t)slot << PAGE_SHIFT_4KB);
	if (old_folio) {
		unsigned long off = __pte_to_phys(vmf->orig_pte) & ~PAGE_MASK_KERNEL;
		void *from = kmap_local_page(vmf->page);
		unsigned long left = copy_mc_to_kernel(to, from + off, PAGE_SIZE_4KB);

		kunmap_local(from);
		if (left) {
			kunmap_local(to);
			goto unlock;	/* the normal path reports the poison */
		}
	} else {
		memset(to, 0, PAGE_SIZE_4KB);
	}
	kunmap_local(to);
	/* The slot's new data must reach the instruction side of an exec mapping */
	flush_dcache_folio(folio);

	if (old_folio) {
		dec_mm_counter(mm, mm_counter_file(old_folio));
	} else {
		ksm_might_unmap_zero_page(mm, vmf->orig_pte);
	}
	inc_mm_counter(mm, MM_ANONPAGES);

	flush_cache_page(vma, addr, pte_pfn(vmf->orig_pte));
	entry = vma_folio_mk_pte(vma, folio, addr);
	entry = pte_sw_mkyoung(entry);
	entry = maybe_mkwrite(pte_mkdirty(entry), vma);
	ptep_clear_flush(vma, addr, vmf->pte);
	atomic_inc(&folio->_mapcount);
	folio_ref_inc(folio);
	smp_wmb();	/* the copy before the PTE, as __folio_mark_uptodate() */
	set_pte_at(mm, addr, vmf->pte, entry);
	update_mmu_cache_range(vmf, vma, addr, vmf->pte, 1);
	if (old_folio) {
		/* after the PTE switch, as in wp_page_copy() */
		folio_remove_rmap_pte(old_folio, vmf->page, vma);
		folio_put(old_folio);
	}
	done = true;
unlock:
	pte_unmap_unlock(vmf->pte, vmf->ptl);
out:
	mmu_notifier_invalidate_range_end(&range);
	return done;
}

/**
 * p3s_cow_fault_read_first - Should a private file write fault map read-only?
 * @vmf: Write fault on a not-present PTE of a private file mapping
 *
 * do_cow_fault() allocates a new folio for the faulting slice. When a sibling
 * folio could take the copy instead, map the page cache page read-only: the
 * retried write then copies it through p3s_wp_copy_into_sibling().
 */
bool p3s_cow_fault_read_first(struct vm_fault *vmf)
{
	struct vm_area_struct *vma = vmf->vma;
	unsigned long addr = vmf->address & PAGE_MASK_4KB;
	unsigned int nr_slices;
	unsigned long start;
	bool found = false;
	spinlock_t *ptl;
	pte_t *pte;

	if (!p3s_cow_vma_ok(vma, vmf) || !vmf->pmd || pmd_none(pmdp_get_lockless(vmf->pmd)))
		return false;
	vma_folio_slice_bounds(vma, addr, &nr_slices, &start);
	if (nr_slices < 2)
		return false;
	pte = pte_offset_map_lock(vma->vm_mm, vmf->pmd, start, &ptl);
	if (!pte)
		return false;
	found = !!p3s_cow_sibling(vma, pte, start, nr_slices, addr, false);
	pte_unmap_unlock(pte, ptl);
	return found;
}
