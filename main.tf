resource "google_compute_image" "redis-image" {
  name = "redis-image"

  raw_disk {
    source = var.raw_image_source
  }
  timeouts {
    create = "10m"
  }
}

data "template_file" "redis_stackdriver" {
  count    = var.node_count
  template = file("${path.module}/redis-stackdriver.conf.tpl")

  vars = {
    hostname = "${var.instance_name}-${count.index}"
  }
}

resource "google_compute_instance" "redis_instance" {
  name         = "${var.instance_name}-${count.index}"
  machine_type = "n1-standard-1"
  zone         = var.zone
  count        = var.node_count

  tags = ["redis"]

  boot_disk {
    initialize_params {
      image = google_compute_image.redis-image.self_link
      type  = "pd-ssd"
      size  = "20"
    }
  }

  network_interface {
    network = "default"

    access_config {
      // Ephemeral IP
    }
  }

  metadata = {
    ssh-keys = "devops:${tls_private_key.provision_key.public_key_openssh}"
  }

  service_account {
    scopes = ["userinfo-email", "compute-ro", "storage-rw", "monitoring-write", "logging-write", "https://www.googleapis.com/auth/trace.append"]
  }

  provisioner "file" {
    content     = data.template_file.redis_stackdriver[count.index].rendered
    destination = "/tmp/redis-stackdriver.conf"

    connection {
      host        = "${google_compute_instance.redis_instance[count.index].network_interface.0.access_config.0.nat_ip}"
      type        = "ssh"
      user        = "devops"
      private_key = tls_private_key.provision_key.private_key_pem
      agent       = false
    }
  }

  provisioner "remote-exec" {
    connection {
      host        = "${google_compute_instance.redis_instance[count.index].network_interface.0.access_config.0.nat_ip}"
      type        = "ssh"
      user        = "devops"
      private_key = tls_private_key.provision_key.private_key_pem
      agent       = false
    }

    inline = [
      "sudo systemctl start redis.service",
      "sudo mv /tmp/redis-stackdriver.conf /opt/stackdriver/collectd/etc/collectd.d/redis.conf",
    ]
  }

  allow_stopping_for_update = false
}

resource "tls_private_key" "provision_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "google_compute_firewall" "redis-allow-cluster" {
  name     = "redis-allow-cluster-${var.instance_name}"
  network  = "default"
  priority = "1000"

  allow {
    protocol = "tcp"
    ports    = ["6379"]
  }
  source_ranges = [var.cluster_ipv4_cidr]
  source_tags   = ["redis"]
}

