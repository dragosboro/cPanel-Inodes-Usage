<?php
require_once "/usr/local/cpanel/php/cpanel.php";
$cpanel = new CPANEL();
$subfolder = $_GET['subfolder'] ?? '';

if (!$subfolder || !is_dir($subfolder)) {
    echo json_encode([]);
    exit;
}

// Function to count inodes (files, folders, and symlinks)
function count_inodes($directory) {
    $inode_count = 1; // Start with 1 to include the directory itself
    $objects = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($directory, RecursiveDirectoryIterator::SKIP_DOTS),
        RecursiveIteratorIterator::SELF_FIRST
    );
    foreach ($objects as $name => $object) {
        if ($object->isFile() || $object->isLink()) {
            $inode_count++;
        } elseif ($object->isDir() && !$object->isLink()) {
            $inode_count++;
        }
    }
    return $inode_count;
}

// Function to check if a directory has subfolders
function has_subfolders($directory) {
    foreach (new DirectoryIterator($directory) as $fileInfo) {
        if ($fileInfo->isDir() && !$fileInfo->isDot() && !$fileInfo->isLink()) {
            return true;
        }
    }
    return false;
}

// Function to get subfolders and their inode counts
function get_subfolders($directory) {
    $subfolders = array();
    foreach (new DirectoryIterator($directory) as $fileInfo) {
        if ($fileInfo->isDir() && !$fileInfo->isDot() && !$fileInfo->isLink()) {
            $path = $fileInfo->getPathname();
            $inode_count = count_inodes($path, $user_uid);
            $subfolders[] = array("path" => $path, "inodes" => $inode_count, "has_subfolders" => has_subfolders($path));
        }
    }
    // Sort subfolders by inode count in descending order
    usort($subfolders, function($a, $b) {
        return $b['inodes'] - $a['inodes'];
    });
    return $subfolders;
}

$subfolders = get_subfolders($subfolder);
echo json_encode($subfolders);
?>
