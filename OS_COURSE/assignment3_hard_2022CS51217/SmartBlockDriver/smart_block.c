#include <linux/init.h>
#include <linux/initrd.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/major.h>
#include <linux/blkdev.h>
#include <linux/bio.h>
#include <linux/highmem.h>
#include <linux/mutex.h>
#include <linux/radix-tree.h>
#include <linux/fs.h>
#include <linux/slab.h>
#include <linux/backing-dev.h>
#include <linux/uaccess.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/blk-mq.h>
#include <linux/file.h>
#include <linux/mm.h>
#include <linux/fs_struct.h>
#include <linux/workqueue.h>
#define MY_BLOCK_MAJOR_TRIAL 0
#define MY_BLKDEV_NAME  "smart_block"
#define DEVICE_MINOR_NUMS_MAX 16
#define DEVICE_MINOR_NUM_FIRST 0
#define MYBLK_SIZE_SECT (4 * 1024)
#define KERNEL_SECTOR_SIZE 512
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Sarthak");
MODULE_DESCRIPTION("A smart block device driver with statistics tracking");
static unsigned long cache_size_bytes = 1024 * 1024; 
module_param(cache_size_bytes, ulong, 0644);
MODULE_PARM_DESC(cache_size_bytes, "Size of write cache in bytes (default: 1MB)");
static char *backing_file_path = "/tmp/smart_block.img";
module_param(backing_file_path, charp, 0644);
MODULE_PARM_DESC(backing_file_path, "Path to backing file (default: /tmp/smart_block.img)");
int major_num;
static spinlock_t smart_block_lock;
static struct request_queue *smart_block_req_qu;
static struct gendisk *smart_block_disk;
struct pending_work {
    struct list_head list;
    struct cache_entry *entry;
};
struct smart_block_dev {
    unsigned long size;                 
    struct file *storage_file; 
    atomic_long_t cache_size;           
    atomic_long_t write_count;          
    spinlock_t lock;                    
    struct list_head cache_list;        
    unsigned long max_cache_size;       
    struct workqueue_struct *wq;
    struct work_struct flush_work;
    struct list_head pending_writes;
    spinlock_t pending_lock; 
};
struct cache_entry {
    sector_t sector;
    unsigned int num_sectors;
    u8 *data;
    struct list_head list;
};
static struct smart_block_dev *smart_block_device = NULL;
static struct proc_dir_entry *proc_parent = NULL;
static struct proc_dir_entry *proc_stats = NULL;
static struct proc_dir_entry *proc_cache_size = NULL;
static struct proc_dir_entry *proc_flush = NULL;
static void __flush_cache_unsafe(struct smart_block_dev *dev);
static int smart_block_proc_show(struct seq_file *m, void *v)
{
    struct smart_block_dev *dev = pde_data(file_inode(m->file));
    seq_printf(m, "Maximum size: %lu bytes\nCache Used: %ld bytes\nNumber of Writes Done To Disk: %ld\n",
               dev->max_cache_size,
               atomic_long_read(&dev->cache_size),
               atomic_long_read(&dev->write_count));
    return 0;
}
static int smart_block_proc_open(struct inode *inode, struct file *file)
{
    return single_open(file, smart_block_proc_show, NULL);
}
static const struct proc_ops smart_block_proc_ops = {
    .proc_open = smart_block_proc_open,
    .proc_read = seq_read,
    .proc_lseek = seq_lseek,
    .proc_release = single_release,
};
static int smart_block_cache_size_show(struct seq_file *m, void *v) {
    struct smart_block_dev *dev = m->private;
    unsigned long cache_size;
    unsigned long flags;
    spin_lock_irqsave(&dev->lock,flags);
    cache_size = dev->max_cache_size;
    spin_unlock_irqrestore(&dev->lock,flags);
    seq_printf(m, "%lu\n", cache_size);
    return 0;
}
static ssize_t smart_block_cache_size_write(struct file *file, const char __user *buffer,
                                         size_t count, loff_t *ppos) {
    struct smart_block_dev *dev = pde_data(file_inode(file));
    char buf[32];
    unsigned long new_size;
    int err;
    unsigned long flags;
    if (count >= sizeof(buf))
        return -EINVAL;
    if (copy_from_user(buf, buffer, count))
        return -EFAULT;
    buf[count] = '\0';
    err = kstrtoul(buf, 10, &new_size);
    if (err)
        return err;
    spin_lock_irqsave(&dev->lock,flags);
    dev->max_cache_size = new_size;
    if (atomic_long_read(&dev->cache_size) >= dev->max_cache_size) {
        __flush_cache_unsafe(dev);
        queue_work(dev->wq, &dev->flush_work);
    }
    spin_unlock_irqrestore(&dev->lock,flags);
    return count;
}
static int smart_block_cache_size_open(struct inode *inode, struct file *file) {
    return single_open(file, smart_block_cache_size_show, pde_data(inode));
}
static const struct proc_ops smart_block_cache_size_ops = {
    .proc_open = smart_block_cache_size_open,
    .proc_read = seq_read,
    .proc_write = smart_block_cache_size_write,
    .proc_lseek = seq_lseek,
    .proc_release = single_release,
};
static void flush_work_fn(struct work_struct *work) {
    struct smart_block_dev *dev = container_of(work, struct smart_block_dev, flush_work);
    struct pending_work *pwork, *tmp;
    struct cache_entry *entry;
    unsigned long flags;
    loff_t pos;
    spin_lock_irqsave(&dev->pending_lock,flags);
    list_for_each_entry_safe(pwork, tmp, &dev->pending_writes, list) {
        list_del(&pwork->list);
        spin_unlock_irqrestore(&dev->pending_lock,flags);
        entry = pwork->entry;
        pos = entry->sector * KERNEL_SECTOR_SIZE;
        kernel_write(dev->storage_file, entry->data, 
                   entry->num_sectors * KERNEL_SECTOR_SIZE, &pos);
        atomic_long_inc(&dev->write_count);
        kfree(entry->data);
        kfree(entry);
        kfree(pwork);
        spin_lock_irqsave(&dev->pending_lock,flags);
    }
    spin_unlock_irqrestore(&dev->pending_lock,flags);
}
static void __flush_cache_unsafe(struct smart_block_dev *dev) {
    struct cache_entry *entry, *tmp;
    struct pending_work *work;
    list_for_each_entry_safe(entry, tmp, &dev->cache_list, list) {
        list_del(&entry->list);
        atomic_long_sub(entry->num_sectors * KERNEL_SECTOR_SIZE, &dev->cache_size);
        work = kmalloc(sizeof(*work), GFP_ATOMIC);
        if (work) {
            unsigned long flags;
            INIT_LIST_HEAD(&work->list);
            work->entry = entry;
            spin_lock_irqsave(&dev->pending_lock,flags);
            list_add_tail(&work->list, &dev->pending_writes);
            spin_unlock_irqrestore(&dev->pending_lock,flags);
        }else {
            loff_t pos = entry->sector * KERNEL_SECTOR_SIZE;
            kernel_write(dev->storage_file, entry->data, 
                       entry->num_sectors * KERNEL_SECTOR_SIZE, &pos);
            atomic_long_inc(&dev->write_count);
            kfree(entry->data);
            kfree(entry);
        }
    }
}
static void flush_cache(struct smart_block_dev *dev) {
    unsigned long flags;
    spin_lock_irqsave(&dev->lock, flags);
    __flush_cache_unsafe(dev);
    spin_unlock_irqrestore(&dev->lock, flags);
    queue_work(dev->wq, &dev->flush_work);
}
static ssize_t smart_block_flush_write(struct file *file, const char __user *buffer,
                                    size_t count, loff_t *ppos) {
    struct smart_block_dev *dev = pde_data(file_inode(file));
    char buf[7];
    if (count > 6)
        return -EINVAL;
    if (copy_from_user(buf, buffer, count))
        return -EFAULT;
    buf[count] = '\0';
    if (strncmp(buf, "flush", 5) != 0)
        return -EINVAL;
    flush_cache(dev);
    return count;
}
static const struct proc_ops smart_block_flush_ops = {
    .proc_open = simple_open,
    .proc_write = smart_block_flush_write,
    .proc_lseek = noop_llseek,
};
static void smart_block_transfer(struct smart_block_dev *dev, sector_t sector,
                              unsigned int nsect, char *buffer, int write)
{
    unsigned long offset = sector * KERNEL_SECTOR_SIZE;
    unsigned long nbytes = nsect * KERNEL_SECTOR_SIZE;
    unsigned long flags;
    if ((offset + nbytes) > dev->size * KERNEL_SECTOR_SIZE) {
        printk(KERN_NOTICE "smart_block: Beyond-end %s (%ld %lu)\n",
               write ? "write" : "read", offset, nbytes);
        return;
    }
    if (write) {
        struct cache_entry *entry = kmalloc(sizeof(*entry), GFP_ATOMIC);
        if (!entry) {
            printk(KERN_ERR "smart_block: Cache entry alloc failed\n");
            return;
        }
        entry->data = kmalloc(nbytes, GFP_ATOMIC);
        if (!entry->data) {
            kfree(entry);
            printk(KERN_ERR "smart_block: Data alloc failed\n");
            return;
        }
        memcpy(entry->data, buffer, nbytes);
        entry->sector = sector;
        entry->num_sectors = nsect;
        spin_lock_irqsave(&dev->lock, flags);
        list_add_tail(&entry->list, &dev->cache_list);
        atomic_long_add(nbytes, &dev->cache_size);
        if (atomic_long_read(&dev->cache_size) >= dev->max_cache_size) {
            __flush_cache_unsafe(dev);
            queue_work(dev->wq, &dev->flush_work);
        }
        spin_unlock_irqrestore(&dev->lock, flags);
    } else {
        unsigned char *sectors_handled;
        struct cache_entry *entry;
        unsigned long flags;
        loff_t pos = offset;
        kernel_read(dev->storage_file, buffer, nbytes, &pos);
        sectors_handled = kzalloc(nsect, GFP_ATOMIC);
        if (!sectors_handled) {
            printk(KERN_ERR "smart_block: Sector tracker alloc failed. Using disk data.\n");
            return;
        }
        spin_lock_irqsave(&dev->lock,flags);
        list_for_each_entry_reverse(entry, &dev->cache_list, list) {
            sector_t entry_start = entry->sector;
            sector_t entry_end = entry_start + entry->num_sectors;
            sector_t req_end = sector + nsect;
            sector_t overlap_start,overlap_end;
            if (entry_end <= sector || entry_start >= req_end) continue;
            overlap_start = max(entry_start, sector);
            overlap_end = min(entry_end, req_end);
            for (sector_t s = overlap_start; s < overlap_end; s++) {
                unsigned idx = s - sector;
                if (!sectors_handled[idx]) {
                    unsigned long buf_offset = idx * KERNEL_SECTOR_SIZE;
                    unsigned long cache_offset = (s - entry_start) * KERNEL_SECTOR_SIZE;
                    memcpy(buffer + buf_offset, entry->data + cache_offset, KERNEL_SECTOR_SIZE);
                    sectors_handled[idx] = 1; 
                }
            }
        }
        spin_unlock_irqrestore(&dev->lock,flags);
        kfree(sectors_handled);
    }
}
static blk_status_t smart_block_queue_rq(struct blk_mq_hw_ctx *hctx,
                                     const struct blk_mq_queue_data *bd)
{
    struct request *rq = bd->rq;
    struct smart_block_dev *dev = smart_block_device;
    struct req_iterator iter;
    struct bio_vec bvec;
    sector_t pos = blk_rq_pos(rq);
    blk_status_t ret = BLK_STS_OK;
    blk_mq_start_request(rq);
    if (req_op(rq) == REQ_OP_FLUSH) {
        flush_cache(dev);
        goto done;
    }
    if (blk_rq_is_passthrough(rq)) {
        printk(KERN_NOTICE "smart_block: Skip non-fs request\n");
        ret = BLK_STS_IOERR;
        goto done;
    }
    rq_for_each_segment(bvec, rq, iter) {
        unsigned int len = bvec.bv_len;
        void *buffer = page_address(bvec.bv_page) + bvec.bv_offset;
        int dir = rq_data_dir(rq);
        smart_block_transfer(dev, pos, len / KERNEL_SECTOR_SIZE, buffer, dir);
        pos += len / KERNEL_SECTOR_SIZE;
    }
done:
    blk_mq_end_request(rq, ret);
    return BLK_STS_OK;
}
static struct blk_mq_ops smart_block_mq_ops = {
    .queue_rq = smart_block_queue_rq,
};
static const struct block_device_operations smart_block_fops = {
    .owner = THIS_MODULE,
};
static __init int my_block_init(void)
{
    int ret = 0;
    struct blk_mq_tag_set *tag_set;
    int ret1;
    major_num = register_blkdev(MY_BLOCK_MAJOR_TRIAL, MY_BLKDEV_NAME);
    if (major_num < 0) {
        printk(KERN_ERR "smart_block: Unable to register block device\n");
        return -EBUSY;
    }
    smart_block_device = kzalloc(sizeof(struct smart_block_dev), GFP_KERNEL);
    if (!smart_block_device) {
        printk(KERN_ERR "smart_block: Failed to allocate device structure\n");
        ret = -ENOMEM;
        goto err_unregister;
    }
    INIT_LIST_HEAD(&smart_block_device->cache_list);
    INIT_WORK(&smart_block_device->flush_work, flush_work_fn);
    smart_block_device->wq = alloc_workqueue("smart_block_flush", WQ_MEM_RECLAIM | WQ_HIGHPRI, 1);
    INIT_LIST_HEAD(&smart_block_device->pending_writes);
    spin_lock_init(&smart_block_device->pending_lock);
    smart_block_device->size = MYBLK_SIZE_SECT;
    smart_block_device->storage_file = filp_open(backing_file_path, O_RDWR | O_CREAT, 0600);
    if (IS_ERR(smart_block_device->storage_file)) {
        printk(KERN_ERR "smart_block: Failed to open backing file %s\n", backing_file_path);
        ret = PTR_ERR(smart_block_device->storage_file);
        goto err_free_dev;
    }
    spin_lock_init(&smart_block_device->lock);
    spin_lock_init(&smart_block_lock);
    atomic_long_set(&smart_block_device->cache_size, 0);
    atomic_long_set(&smart_block_device->write_count, 0);
    smart_block_device->max_cache_size=cache_size_bytes;
    tag_set = kzalloc(sizeof(*tag_set), GFP_KERNEL);
    if (!tag_set) {
        printk(KERN_ERR "smart_block: Failed to allocate tag set\n");
        ret = -ENOMEM;
        goto err_free_data;
    }
    tag_set->ops = &smart_block_mq_ops;
    tag_set->nr_hw_queues = 1;
    tag_set->queue_depth = 128;
    tag_set->numa_node = NUMA_NO_NODE;
    tag_set->cmd_size = 0;
    tag_set->flags = BLK_MQ_F_SHOULD_MERGE | BLK_MQ_F_BLOCKING;
    tag_set->driver_data = smart_block_device;
    ret = blk_mq_alloc_tag_set(tag_set);
    if (ret) {
        printk(KERN_ERR "smart_block: Failed to allocate tag set\n");
        goto err_free_tagset;
    }
    smart_block_disk = blk_alloc_disk(NUMA_NO_NODE);
    if (!smart_block_disk) {
        printk(KERN_ERR "smart_block: Failed to allocate gendisk structure\n");
        ret = -ENOMEM;
        goto err_free_tag_set;
    }
    smart_block_req_qu = smart_block_disk->queue;
    ret = blk_mq_init_allocated_queue(tag_set, smart_block_req_qu);
    if (ret) {
        printk(KERN_ERR "smart_block: Failed to initialize queue\n");
        goto err_put_disk;
    }
    blk_queue_flag_set(QUEUE_FLAG_NONROT, smart_block_req_qu);
    blk_queue_logical_block_size(smart_block_req_qu, KERNEL_SECTOR_SIZE);
    blk_queue_write_cache(smart_block_req_qu, true, false);
    smart_block_disk->major = major_num;
    smart_block_disk->first_minor = DEVICE_MINOR_NUM_FIRST;
    smart_block_disk->minors = DEVICE_MINOR_NUMS_MAX;
    strcpy(smart_block_disk->disk_name, MY_BLKDEV_NAME);
    smart_block_disk->fops = &smart_block_fops;
    smart_block_disk->queue = smart_block_req_qu;
    smart_block_disk->private_data = smart_block_device;
    set_capacity(smart_block_disk, MYBLK_SIZE_SECT);
    ret1 = add_disk(smart_block_disk);
    if (ret1) {
        pr_err("Failed to add disk\n");
        goto err_put_disk;
    }
    proc_parent = proc_mkdir(MY_BLKDEV_NAME, NULL);
    if (!proc_parent) {
        printk(KERN_ERR "smart_block: Failed to create proc directory\n");
        ret = -ENOMEM;
        goto err_del_disk;
    }
    proc_stats = proc_create_data("stats", 0444, proc_parent, &smart_block_proc_ops, smart_block_device);
    proc_cache_size = proc_create_data("cache_size", 0644, proc_parent, &smart_block_cache_size_ops, smart_block_device);
    proc_flush = proc_create_data("flush", 0222, proc_parent, &smart_block_flush_ops, smart_block_device);
    if (!proc_stats) {
        printk(KERN_ERR "smart_block: Failed to create proc entry\n");
        ret = -ENOMEM;
        goto err_remove_proc_parent;
    }
    printk(KERN_INFO "smart_block: Initialized successfully\n");
    return 0;
err_remove_proc_parent:
    proc_remove(proc_parent);
err_del_disk:
    del_gendisk(smart_block_disk);
err_put_disk:
    put_disk(smart_block_disk);
err_free_tag_set:
    blk_mq_free_tag_set(tag_set);
err_free_tagset:
    kfree(tag_set);
err_free_data:
    filp_close(smart_block_device->storage_file, NULL);
err_free_dev:
    kfree(smart_block_device);
err_unregister:
    unregister_blkdev(major_num, MY_BLKDEV_NAME);
return ret;
}
static __exit void my_block_exit(void)
{
    if (smart_block_device->wq) {
        flush_workqueue(smart_block_device->wq);
        destroy_workqueue(smart_block_device->wq);
    }
    if (proc_stats)
        proc_remove(proc_stats);
    if (proc_parent)
        proc_remove(proc_parent);
    if (proc_flush)
        proc_remove(proc_flush);
    if (proc_parent)
        proc_remove(proc_parent);
    if (smart_block_disk) {
        del_gendisk(smart_block_disk);
        put_disk(smart_block_disk);
    }
    if (smart_block_device) {
        if (smart_block_device->storage_file){
            filp_close(smart_block_device->storage_file, NULL);
        }
        kfree(smart_block_device);
    }
    unregister_blkdev(major_num, MY_BLKDEV_NAME);
    printk(KERN_INFO "smart_block: Module unloaded successfully\n");
}
module_init(my_block_init);
module_exit(my_block_exit);