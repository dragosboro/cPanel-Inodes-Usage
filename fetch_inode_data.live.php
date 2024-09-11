<?php

// Load cPanel environment
require_once "/usr/local/cpanel/php/cpanel.php";

// Initialize cPanel API
$cpanel = new CPANEL();

// Fetch the user and home directory information
$username = getenv('REMOTE_USER');

if (!$username) {
    echo json_encode(['error' => 'Cannot determine username from environment']);
    exit;
}

// Determine the user's real home directory path
$user_info = posix_getpwnam($username);
$user_uid = $user_info['uid']; // Get the UID of the cPanel user
$home_dir = $user_info['dir'];

if (!file_exists($home_dir)) {
    echo json_encode(['error' => 'Cannot determine home directory for user ' . $username]);
    exit;
}

// Function to count inodes (files, folders, and symlinks)
function count_inodes($directory, $user_uid) {
    $inode_count = 1; // Start with 1 to include the directory itself
    $objects = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($directory, RecursiveDirectoryIterator::SKIP_DOTS),
        RecursiveIteratorIterator::SELF_FIRST
    );

    foreach ($objects as $name => $object) {
        // Check if the file/folder is owned by the cPanel user
        if (fileowner($object->getPathname()) !== $user_uid) {
            continue; // Skip counting this inode if it's not owned by the user
        }

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

// Fetch inode information for top-level directories only
$directories = array();
foreach (new DirectoryIterator($home_dir) as $fileInfo) {
    if ($fileInfo->isDir() && !$fileInfo->isDot() && !$fileInfo->isLink()) {
        $path = $fileInfo->getPathname();
        $inode_count = count_inodes($path, $user_uid);
        $directories[] = array("path" => $path, "inodes" => $inode_count, "has_subfolders" => has_subfolders($path));
    }
}

// Sort directories by inode count in descending order
usort($directories, function($a, $b) {
    return $b['inodes'] - $a['inodes'];
});

// Calculate the total inodes for the home directory
$total_inodes = count_inodes($home_dir, $user_uid);

// Fetch quota information
$quota_info = $cpanel->uapi(
    'Quota',
    'get_quota_info'
);

$inode_limit = isset($quota_info['cpanelresult']['result']['data']['inode_limit']) && $quota_info['cpanelresult']['result']['data']['inode_limit'] != 0 
    ? $quota_info['cpanelresult']['result']['data']['inode_limit'] 
    : 'Unlimited';

// Output JSON for the frontend
echo json_encode(array("directories" => $directories, "total_inodes" => $total_inodes, "inode_limit" => $inode_limit));

?>
